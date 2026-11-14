import Foundation
import System

/// Locates Homebrew and enumerates installed formulae and casks.
///
/// Never throws: every failure becomes a diagnostic. `packagesEnumerated` is true only when an
/// inventory was obtained, so callers can tell "nothing installed" from "could not ask".
/// Prefers `brew info --json=v2 --installed`, falling back to `brew list --versions`.
public func discoverHomebrew(_ runner: any CommandRunner) -> BrewDiscoveryResult {
    var result = BrewDiscoveryResult()

    // 1. Locate brew executable
    guard let brewPath = runner.findExecutable("brew") else {
        result.diagnostics.append(.warning(
            "Homebrew executable ('brew') not found on PATH or standard macOS locations (/opt/homebrew/bin/brew, /usr/local/bin/brew)."
        ))
        return result
    }

    result.available = true
    result.brewPath = brewPath

    // 2. Query brew version
    do {
        let out = try runBrewCommand(runner, brewPath, ["--version"])
        let firstLine = rustLines(out.stdout).first.map(rustTrim) ?? ""
        if !firstLine.isEmpty {
            result.brewVersion = firstLine
        }
    } catch {
        result.diagnostics.append(
            Diagnostic.warning("Failed to determine Homebrew version").withDetail(error.description)
        )
    }

    // 3. Query installed packages
    switch queryPackagesJSON(runner, brewPath) {
    case .success(let (formulae, casks)):
        result.packagesEnumerated = true
        result.formulae = formulae
        result.casks = casks
    case .failure(let jsonError):
        switch queryPackagesList(runner, brewPath) {
        case .success(let (formulae, casks)):
            result.packagesEnumerated = true
            result.formulae = formulae
            result.casks = casks
            result.diagnostics.append(
                Diagnostic.info(
                    "Used fallback 'brew list --versions' after JSON inspection was unavailable"
                ).withDetail(jsonError.message)
            )
        case .failure(let listError):
            result.packagesEnumerated = false
            result.diagnostics.append(
                Diagnostic.error("Failed to query installed Homebrew packages").withDetail(
                    "JSON query error: \(jsonError.message); list fallback error: \(listError.message)"
                )
            )
        }
    }

    return result
}

/// Parses `brew list --versions` output: `name [version...]` per line; blank lines skipped,
/// multiple versions joined by a single space. Order is preserved.
public func parseListVersionsOutput(_ output: String, kind: PackageKind) -> [ObservedPackage] {
    var packages: [ObservedPackage] = []
    for line in rustLines(output) {
        let trimmed = rustTrim(line)
        if trimmed.isEmpty { continue }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let name = parts.first else { continue }
        let version = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : nil
        packages.append(ObservedPackage(name: name, kind: kind, version: version, installed: true))
    }
    return packages
}

// MARK: - Helpers

private struct DiscoveryError: Error {
    var message: String
}

private typealias Inventory = ([ObservedPackage], [ObservedPackage])

private func runBrewCommand(
    _ runner: any CommandRunner, _ brewPath: FilePath, _ args: [String]
) throws(RunnerError) -> CommandOutput {
    try runner.run(brewPath.string, args: args)
}

private func queryPackagesJSON(
    _ runner: any CommandRunner, _ brewPath: FilePath
) -> Result<Inventory, DiscoveryError> {
    let out: CommandOutput
    do {
        out = try runBrewCommand(runner, brewPath, ["info", "--json=v2", "--installed"])
    } catch {
        return .failure(DiscoveryError(message: error.description))
    }

    let value: Any
    do {
        value = try JSONSerialization.jsonObject(
            with: Data(out.stdout.utf8), options: [.fragmentsAllowed])
    } catch {
        return .failure(DiscoveryError(
            message: "Failed to parse 'brew info' JSON: \(error.localizedDescription)"))
    }

    guard let object = value as? [String: Any] else {
        return .failure(DiscoveryError(message: "Root JSON response is not an object"))
    }

    guard let formulaeValue = object["formulae"] else {
        return .failure(DiscoveryError(message: "JSON response missing 'formulae' field"))
    }
    guard let formulaeArray = formulaeValue as? [Any] else {
        return .failure(DiscoveryError(message: "'formulae' field is not an array"))
    }

    var formulae: [ObservedPackage] = []
    for item in formulaeArray {
        guard let dict = item as? [String: Any], let name = jsonString(dict["name"]) else {
            continue
        }
        let firstInstalled = (dict["installed"] as? [Any])?.first as? [String: Any]
        let version = jsonString(firstInstalled?["version"])
        formulae.append(ObservedPackage(name: name, kind: .formula, version: version, installed: true))
    }

    guard let casksValue = object["casks"] else {
        return .failure(DiscoveryError(message: "JSON response missing 'casks' field"))
    }
    guard let casksArray = casksValue as? [Any] else {
        return .failure(DiscoveryError(message: "'casks' field is not an array"))
    }

    var casks: [ObservedPackage] = []
    for item in casksArray {
        guard let dict = item as? [String: Any] else { continue }
        // Rust: `get("token").or_else(|| get("name")).and_then(as_str)` — a present but
        // non-string `token` does not fall back to `name`.
        let nameValue = dict["token"] ?? dict["name"]
        guard let token = jsonString(nameValue) else { continue }
        let version = jsonString(dict["version"])
        casks.append(ObservedPackage(name: token, kind: .cask, version: version, installed: true))
    }

    return .success((sortedByName(formulae), sortedByName(casks)))
}

private func queryPackagesList(
    _ runner: any CommandRunner, _ brewPath: FilePath
) -> Result<Inventory, DiscoveryError> {
    let formulaOut: CommandOutput
    do {
        formulaOut = try runBrewCommand(runner, brewPath, ["list", "--versions", "--formula"])
    } catch {
        return .failure(DiscoveryError(
            message: "'brew list --versions --formula' failed: \(error.description)"))
    }
    let formulae = parseListVersionsOutput(formulaOut.stdout, kind: .formula)

    let caskOut: CommandOutput
    do {
        caskOut = try runBrewCommand(runner, brewPath, ["list", "--versions", "--cask"])
    } catch {
        return .failure(DiscoveryError(
            message: "'brew list --versions --cask' failed: \(error.description)"))
    }
    let casks = parseListVersionsOutput(caskOut.stdout, kind: .cask)

    return .success((sortedByName(formulae), sortedByName(casks)))
}

/// JSON string values only (`NSNumber`/`NSNull` etc. yield nil, like `Value::as_str`).
private func jsonString(_ value: Any?) -> String? {
    guard let string = value as? String, !(value is NSNumber) else { return nil }
    return string
}

/// Stable sort by byte-wise name comparison (Rust `String::cmp`).
private func sortedByName(_ packages: [ObservedPackage]) -> [ObservedPackage] {
    packages.enumerated().sorted { lhs, rhs in
        let l = Array(lhs.element.name.utf8)
        let r = Array(rhs.element.name.utf8)
        if l != r { return l.lexicographicallyPrecedes(r) }
        return lhs.offset < rhs.offset
    }.map(\.element)
}

/// Rust `str::lines`: split on `\n`, strip one trailing `\r`, no trailing empty line.
private func rustLines(_ text: String) -> [String] {
    // Split on unicode scalars so "\r\n" (a single Character) is still separated at "\n".
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if scalar == "\n" {
            lines.append(stripTrailingCR(current))
            current = String.UnicodeScalarView()
        } else {
            current.append(scalar)
        }
    }
    if !current.isEmpty {
        lines.append(stripTrailingCR(current))
    }
    return lines
}

private func stripTrailingCR(_ scalars: String.UnicodeScalarView) -> String {
    var copy = scalars
    if copy.last == "\r" {
        copy.removeLast()
    }
    return String(copy)
}
