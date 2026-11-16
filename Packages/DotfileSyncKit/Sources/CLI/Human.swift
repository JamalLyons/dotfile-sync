// Port of crates/dotfilesync-cli/src/output/human.rs. Text is byte-for-byte the Rust output.

import Core
import IPC
import System

func short10(_ s: String) -> String {
    s.count >= 10 ? String(s.prefix(10)) : s
}

func kindLabel(_ kind: PackageKind) -> String {
    switch kind {
    case .formula: return "formula"
    case .cask: return "cask"
    }
}

/// Human report for `scan`.
public func renderScanReport(_ report: ScanReport) -> String {
    var out = "=== dotfilesync scan ===\n\n"

    out += "HOMEBREW:\n"
    if report.homebrew.available {
        let version = report.homebrew.brewVersion ?? "unknown version"
        let path = report.homebrew.brewPath?.string ?? "path unknown"
        out += "  Status: Available (\(version))\n"
        out += "  Binary: \(path)\n"
        out += "  Installed Formulae (\(report.homebrew.formulae.count)): "
        if report.homebrew.formulae.isEmpty {
            out += "none\n"
        } else {
            out += "\n"
            for f in report.homebrew.formulae {
                out += "    • \(f.name) (\(f.version ?? "installed"))\n"
            }
        }
        out += "  Installed Casks (\(report.homebrew.casks.count)): "
        if report.homebrew.casks.isEmpty {
            out += "none\n"
        } else {
            out += "\n"
            for c in report.homebrew.casks {
                out += "    • \(c.name) (\(c.version ?? "installed"))\n"
            }
        }
    } else {
        out += "  Status: Unavailable (Homebrew not found)\n"
    }

    out += "\nCONFIG FILES (explicitly tracked):\n"
    if report.configs.isEmpty {
        out += "  No tracked configuration files inspected.\n"
    } else {
        for file in report.configs {
            let sha = file.targetHash.map(short10) ?? "-"
            out += "  • Target: \(file.targetPath.string)\n    State:  \(debugCase(file.state)) (SHA256: \(sha))\n"
            if let diag = file.diagnostic {
                out += "    Note:   \(diag)\n"
            }
        }
    }

    appendDiagnostics(report.diagnostics, withDetail: true, to: &out)
    return out
}

private func appendDiagnostics(_ diagnostics: [Diagnostic], withDetail: Bool, to out: inout String) {
    guard !diagnostics.isEmpty else { return }
    out += "\nDIAGNOSTICS:\n"
    for d in diagnostics {
        out += "  [\(debugCase(d.severity))] \(d.message)\n"
        if withDetail, let detail = d.detail {
            out += "    Detail: \(detail)\n"
        }
    }
}

/// Human report for `status`.
public func renderStatusReport(_ report: StatusReport) -> String {
    var out = "=== dotfilesync status ===\n\n"
    let s = report.summary

    out += "SUMMARY:\n"
    let brew = report.homebrewAvailable ? (report.brewVersion ?? "Available") : "Unavailable (diagnostic recorded)"
    out += "  Homebrew:  \(brew)\n"
    out += "  Packages:  \(s.packagesMatching) matching, \(s.packagesMissing) missing, \(s.packagesUnmanaged) unmanaged, \(s.packagesUnknown) unknown\n"
    out += "  Configs:   \(s.configsMatching) matching, \(s.configsChanged) changed (drift), \(s.configsMissing) missing, \(s.configsUnknown) unknown, \(s.configsSkipped) skipped\n"

    let missingPkgs = report.packageDifferences.filter { $0.classification == .missing }
    if !missingPkgs.isEmpty {
        out += "\nMISSING PACKAGES (\(missingPkgs.count)):\n"
        for p in missingPkgs {
            out += "  ✗ [\(kindLabel(p.kind))] \(p.name)\n"
        }
    }

    let unknownPkgs = report.packageDifferences.filter { $0.classification == .unknown }
    if !unknownPkgs.isEmpty {
        out += "\nUNKNOWN STATUS PACKAGES (\(unknownPkgs.count)):\n"
        for p in unknownPkgs {
            out += "  ? [\(kindLabel(p.kind))] \(p.name): \(p.diagnostic ?? "Status cannot be verified")\n"
        }
    }

    let changed = report.configDifferences.filter { $0.classification == .changed }
    if !changed.isEmpty {
        out += "\nCHANGED CONFIG FILES (DRIFT) (\(changed.count)):\n"
        for c in changed {
            let src = short10(c.sourceHash ?? "-")
            let tgt = short10(c.targetHash ?? "-")
            out += "  ⚠ Target: \(c.target.string)\n    Source: \(c.source.string)\n    Repo Hash:   \(src)\n    Machine Hash: \(tgt)\n"
            if let diag = c.diagnostic {
                out += "    Drift note:  \(diag)\n"
            }
        }
    }

    var ordinaryMissing: [ConfigDifference] = []
    var absentOverrides: [ConfigDifference] = []
    for c in report.configDifferences where c.classification == .missing {
        if c.diagnostic?.contains("Machine-local override") ?? false {
            absentOverrides.append(c)
        } else {
            ordinaryMissing.append(c)
        }
    }

    if !ordinaryMissing.isEmpty {
        out += "\nMISSING CONFIG FILES (\(ordinaryMissing.count)):\n"
        for c in ordinaryMissing {
            out += "  ✗ Target: \(c.target.string)\n    Source: \(c.source.string)\n"
        }
    }

    if !absentOverrides.isEmpty {
        out += "\nABSENT MACHINE-LOCAL OVERRIDES (not created on this machine) (\(absentOverrides.count)):\n"
        for c in absentOverrides {
            out += "  ○ Target: \(c.target.string)\n    Note:   Machine-local override is absent on this machine (intentionally local; no repository restoration required)\n"
        }
    }

    let unknownConfigs = report.configDifferences.filter { $0.classification == .unknown }
    if !unknownConfigs.isEmpty {
        out += "\nUNKNOWN STATUS CONFIG FILES (\(unknownConfigs.count)):\n"
        for c in unknownConfigs {
            out += "  ? Target: \(c.target.string)\n    Reason: \(c.diagnostic ?? "Status cannot be verified")\n"
        }
    }

    let skipped = report.configDifferences.filter { $0.classification == .skipped }
    if !skipped.isEmpty {
        out += "\nSKIPPED / MACHINE-LOCAL CONFIGS (\(skipped.count)):\n"
        for c in skipped {
            out += "  - Target: \(c.target.string)\n    Note:   \(c.diagnostic ?? "Skipped")\n"
        }
    }

    let unmanaged = report.packageDifferences.filter { $0.classification == .unmanaged }
    if !unmanaged.isEmpty {
        out += "\nUNMANAGED PACKAGES (installed on system, not declared in manifest) (\(unmanaged.count)):\n"
        for p in unmanaged {
            out += "  • [\(kindLabel(p.kind))] \(p.name) (\(p.observedVersion ?? "installed"))\n"
        }
    }

    appendDiagnostics(report.diagnostics, withDetail: true, to: &out)
    return out
}

/// Human report for `import-brewfile`.
public func renderImportResult(_ result: BrewfileParseResult, outputPath: String?) -> String {
    var out = "=== dotfilesync import-brewfile ===\n\n"
    out += "Imported \(result.formulae.count) formulae and \(result.casks.count) casks statically.\n"
    if let path = outputPath {
        out += "Wrote manifest skeleton to: \(path)\n"
    }
    if !result.unsupportedConstructs.isEmpty {
        out += "\nUNSUPPORTED OR DYNAMIC CONSTRUCTS (\(result.unsupportedConstructs.count)):\n"
        for u in result.unsupportedConstructs {
            out += "  • Line \(u.lineNumber): [\(u.constructType)] \(u.reason)\n    Raw:    \(rustTrim(u.rawLine))\n"
        }
    }
    appendDiagnostics(result.diagnostics, withDetail: false, to: &out)
    return out
}

/// Rust `str::trim` (Unicode `White_Space`).
func rustTrim(_ s: String) -> String {
    let scalars = s.unicodeScalars
    guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
          let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })
    else { return "" }
    return String(scalars[first...last])
}

/// Human plan listing (ends with a newline; printed with `print!`).
public func renderPlan(_ plan: Plan) -> String {
    var out = "Plan \(plan.planId) (profile \(plan.profile ?? "base"))\n"
    if plan.actions.isEmpty {
        out += "No changes. The system matches the manifest.\n"
        return out
    }
    var low = 0, medium = 0, high = 0, reversible = 0
    for action in plan.actions {
        switch action.risk {
        case .low: low += 1
        case .medium: medium += 1
        case .high: high += 1
        }
        if action.reversible { reversible += 1 }
        let rev = action.reversible ? "rev" : "irrev"
        out += "[\(action.risk.rawValue)] [\(rev)] [\(actionTag(action.kind))] \(action.summary)\n"
    }
    let n = plan.actions.count
    let noun = n == 1 ? "action" : "actions"
    out += "\n\(n) \(noun): low \(low), medium \(medium), high \(high); reversible \(reversible), irreversible \(n - reversible)\n"
    return out
}

/// Human run journal (`jobs result` of an apply job).
public func renderRun(_ journal: RunJournal) -> String {
    var out = "Run \(journal.runId) (plan \(journal.planDigest))\n"
    if journal.steps.isEmpty {
        out += "No steps.\n"
        return out
    }
    for step in journal.steps {
        out += "  \(step.actionId)  \(debugCase(step.status))\n"
        if let error = step.error {
            out += "    \(error)\n"
        }
    }
    return out
}

/// Human run view (`runs show`).
func renderRunView(_ view: RunView) -> String {
    var out = "Run \(view.runId)  \(view.status)  plan \(view.planId)  job \(view.jobId)\n"
    if view.steps.isEmpty {
        out += "No steps recorded.\n"
        return out
    }
    for step in view.steps {
        out += "  \(step.actionId)  \(debugCase(step.status))\n"
        if let error = step.error {
            out += "    \(error)\n"
        }
    }
    return out
}

func actionTag(_ kind: ActionKind) -> String {
    switch kind {
    case .brewInstallFormula, .brewInstallCask: return "brew"
    case .linkFile: return "link"
    case .copyFile: return "copy"
    case .ensureLocalOverride: return "ensure"
    case .installFisher, .fisherUpdate: return "fisher"
    case .setLoginShell: return "shell"
    }
}

/// `{:<width}` left padding.
func padRight(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// `serde_json::to_string_pretty`.
func renderJSON<T: Encodable>(_ value: T) throws(CLIError) -> String {
    do {
        return try jsonStringPretty(value)
    } catch {
        throw CLIError(error.description)
    }
}
