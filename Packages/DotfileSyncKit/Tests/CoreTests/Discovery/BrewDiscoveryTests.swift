import Foundation
import System
import Testing

@testable import Core

/// Discovery portions of crates/dotfilesync-core/tests/discovery_and_comparison_tests.rs.
/// Assertions on `compare_status` are deferred to the comparison-engine port.
@Suite("Homebrew discovery")
struct BrewDiscoveryTests {
    private static let brew = "/mock/bin/brew"

    private static func ok(_ stdout: String) -> Result<CommandOutput, RunnerError> {
        .success(CommandOutput(statusCode: 0, stdout: stdout, stderr: ""))
    }

    private static func baseRunner() -> MockCommandRunner {
        MockCommandRunner()
            .withExecutable("brew", FilePath(brew))
            .withResponse(brew, args: ["--version"], ok("Homebrew 4.2.0\n"))
    }

    // Ports test_absent_homebrew_produces_diagnostic_not_missing_packages (discovery part)
    @Test func absentHomebrewProducesDiagnostic() {
        let disc = discoverHomebrew(MockCommandRunner())
        #expect(!disc.available)
        #expect(!disc.packagesEnumerated)
        #expect(disc.formulae.isEmpty)
        #expect(disc.casks.isEmpty)
        #expect(disc.diagnostics.contains { $0.message.contains("not found") })
    }

    // Ports test_failed_query_and_fallback_marks_packages_as_unknown (discovery part)
    @Test func failedQueryAndFallbackLeavesNotEnumerated() throws {
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"],
                          .failure(.nonZeroExit(program: "brew", code: 1, stderr: "Database corrupted")))
            .withResponse(Self.brew, args: ["list", "--versions", "--formula"],
                          .failure(.nonZeroExit(program: "brew", code: 1, stderr: "Cannot list formulae")))
        let disc = discoverHomebrew(runner)
        #expect(disc.available)
        #expect(!disc.packagesEnumerated)
        let diag = try #require(disc.diagnostics.first { $0.severity == .error })
        #expect(diag.message == "Failed to query installed Homebrew packages")
        #expect(diag.detail == "JSON query error: Command 'brew' exited with code 1: Database corrupted; "
            + "list fallback error: 'brew list --versions --formula' failed: "
            + "Command 'brew' exited with code 1: Cannot list formulae")
    }

    // Ports test_malformed_and_unexpected_json_triggers_fallback
    @Test func malformedAndUnexpectedJSONTriggersFallback() {
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"],
                          Self.ok(#"{"error": "unexpected output structure"}"#))
            .withResponse(Self.brew, args: ["list", "--versions", "--formula"], Self.ok("git 2.45.0\n"))
            .withResponse(Self.brew, args: ["list", "--versions", "--cask"], Self.ok("ghostty 1.0.0\n"))
        let disc = discoverHomebrew(runner)
        #expect(disc.available)
        #expect(disc.packagesEnumerated)
        #expect(disc.formulae.count == 1)
        #expect(disc.casks.count == 1)
        #expect(disc.diagnostics.contains { $0.message.contains("fallback") })
        #expect(disc.diagnostics.first { $0.message.contains("fallback") }?.detail
            == "JSON response missing 'formulae' field")
    }

    // Ports test_valid_empty_inventory_is_distinguished_and_enumerated (discovery part)
    @Test func validEmptyInventoryIsEnumerated() {
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"],
                          Self.ok(#"{"formulae": [], "casks": []}"#))
        let disc = discoverHomebrew(runner)
        #expect(disc.available)
        #expect(disc.packagesEnumerated)
        #expect(disc.formulae.isEmpty)
        #expect(disc.casks.isEmpty)
        #expect(disc.diagnostics.isEmpty)
    }

    // Ports test_command_timeout_triggers_fallback
    @Test func commandTimeoutTriggersFallback() {
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"],
                          .failure(.timeout(program: "brew", timeout: .seconds(15))))
            .withResponse(Self.brew, args: ["list", "--versions", "--formula"],
                          Self.ok("git 2.45.0\nfish 3.7.0\n"))
            .withResponse(Self.brew, args: ["list", "--versions", "--cask"], Self.ok("ghostty 1.0.0\n"))
        let disc = discoverHomebrew(runner)
        #expect(disc.available)
        #expect(disc.packagesEnumerated)
        #expect(disc.brewVersion == "Homebrew 4.2.0")
        #expect(disc.formulae.count == 2)
        #expect(disc.casks.count == 1)
        #expect(disc.formulae.map(\.name) == ["fish", "git"])
        #expect(disc.formulae[1].version == "2.45.0")
        #expect(disc.diagnostics.contains { $0.message.contains("fallback") })
    }

    // Ports test_package_comparison_matching_missing_unmanaged (discovery part)
    @Test func jsonInventoryParsed() {
        let json = """
            {
                "formulae": [
                    {"name": "git", "installed": [{"version": "2.44.0"}]},
                    {"name": "unmanaged-tool", "installed": [{"version": "1.0.0"}]}
                ],
                "casks": [
                    {"token": "ghostty", "version": "0.9.0"}
                ]
            }
            """
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"], Self.ok(json))
        let disc = discoverHomebrew(runner)
        #expect(disc.available)
        #expect(disc.packagesEnumerated)
        #expect(disc.formulae == [
            ObservedPackage(name: "git", kind: .formula, version: "2.44.0", installed: true),
            ObservedPackage(name: "unmanaged-tool", kind: .formula, version: "1.0.0", installed: true),
        ])
        #expect(disc.casks == [ObservedPackage(name: "ghostty", kind: .cask, version: "0.9.0", installed: true)])
    }

    // No Rust equivalent: version failure is a warning, not fatal.
    @Test func versionFailureIsWarning() {
        let runner = MockCommandRunner()
            .withExecutable("brew", FilePath(Self.brew))
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"],
                          Self.ok(#"{"formulae": [], "casks": []}"#))
        let disc = discoverHomebrew(runner)
        #expect(disc.brewVersion == nil)
        #expect(disc.packagesEnumerated)
        #expect(disc.diagnostics == [
            Diagnostic.warning("Failed to determine Homebrew version")
                .withDetail("Executable '/mock/bin/brew' was not found"),
        ])
    }

    // No Rust equivalent: parse_list_versions_output edge cases.
    @Test func parseListVersions() {
        let packages = parseListVersionsOutput("  a 1.0 2.0 \n\nb\r\n", kind: .formula)
        #expect(packages == [
            ObservedPackage(name: "a", kind: .formula, version: "1.0 2.0", installed: true),
            ObservedPackage(name: "b", kind: .formula, version: nil, installed: true),
        ])
    }

    // No Rust equivalent: serde-identical JSON shape.
    @Test func jsonEncodingMatchesSerde() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let minimal = String(decoding: try encoder.encode(BrewDiscoveryResult()), as: UTF8.self)
        #expect(minimal == #"{"available":false,"casks":[],"diagnostics":[],"formulae":[],"packages_enumerated":false}"#)

        let full = BrewDiscoveryResult(
            available: true, packagesEnumerated: true, brewPath: FilePath("/opt/homebrew/bin/brew"),
            brewVersion: "Homebrew 4.2.0",
            formulae: [ObservedPackage(name: "git", kind: .formula, installed: true)],
            casks: [ObservedPackage(name: "zed", kind: .cask, version: "1", installed: true)])
        let encoded = String(decoding: try encoder.encode(full), as: UTF8.self)
        #expect(encoded.contains(#""brew_path":"\/opt\/homebrew\/bin\/brew""#))
        #expect(encoded.contains(#""brew_version":"Homebrew 4.2.0""#))
        #expect(encoded.contains(#"{"installed":true,"kind":"formula","name":"git"}"#))
        #expect(encoded.contains(#"{"installed":true,"kind":"cask","name":"zed","version":"1"}"#))
        let decoded = try JSONDecoder().decode(BrewDiscoveryResult.self, from: Data(encoded.utf8))
        #expect(decoded == full)
    }
}
