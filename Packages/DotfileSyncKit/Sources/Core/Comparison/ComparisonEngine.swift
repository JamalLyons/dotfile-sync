// Port of crates/dotfilesync-core/src/comparison/engine.rs.

import System

/// Compares the manifest's desired state with discovered packages and inspected configs.
///
/// Package differences are sorted by kind, classification, then name (UTF-8 byte order);
/// config differences by target path (Rust component-wise `Path` order). Both sorts are stable.
public func compareStatus(
    _ manifest: Manifest,
    brewResult: BrewDiscoveryResult,
    configs: [ObservedConfigFile]
) -> StatusReport {
    var packageDifferences: [PackageDifference] = []
    var summary = StatusSummary()
    var diagnostics = brewResult.diagnostics
    let homebrew = manifest.packageManagers.homebrew

    // 1. Packages
    if !brewResult.available || !brewResult.packagesEnumerated {
        let reason = !brewResult.available
            ? "Homebrew executable is unavailable; status cannot be verified"
            : "Homebrew package inventory enumeration failed; status cannot be verified"

        for (names, kind) in [(homebrew.formulae, PackageKind.formula), (homebrew.casks, .cask)] {
            for name in names {
                packageDifferences.append(PackageDifference(
                    name: name,
                    kind: kind,
                    classification: .unknown,
                    desired: true,
                    diagnostic: reason
                ))
                summary.packagesUnknown += 1
            }
        }
    } else {
        let groups: [([String], [ObservedPackage], PackageKind, String)] = [
            (homebrew.formulae, brewResult.formulae, .formula,
             "Formula is declared in manifest but not installed"),
            (homebrew.casks, brewResult.casks, .cask,
             "Cask is declared in manifest but not installed"),
        ]
        for (desiredNames, observed, kind, missingDiagnostic) in groups {
            // Last entry wins on duplicate names, as Rust `HashMap::from_iter`.
            var installed: [String: ObservedPackage] = [:]
            for package in observed {
                installed[package.name] = package
            }

            var desired = Set<String>()
            for name in desiredNames {
                desired.insert(name)
                if let package = installed[name] {
                    packageDifferences.append(PackageDifference(
                        name: name,
                        kind: kind,
                        classification: .matching,
                        desired: true,
                        installed: true,
                        observedVersion: package.version
                    ))
                    summary.packagesMatching += 1
                } else {
                    packageDifferences.append(PackageDifference(
                        name: name,
                        kind: kind,
                        classification: .missing,
                        desired: true,
                        installed: false,
                        diagnostic: missingDiagnostic
                    ))
                    summary.packagesMissing += 1
                }
            }

            for (name, package) in installed where !desired.contains(name) {
                packageDifferences.append(PackageDifference(
                    name: name,
                    kind: kind,
                    classification: .unmanaged,
                    desired: false,
                    installed: true,
                    observedVersion: package.version,
                    diagnostic: "Installed on system but not declared in manifest"
                ))
                summary.packagesUnmanaged += 1
            }
        }
    }

    // 2. Configs
    var configDifferences: [ConfigDifference] = []
    for observed in configs {
        if [.unreadable, .sourceMissing, .sourceOutsideRoot].contains(observed.state),
           let error = observed.diagnostic {
            diagnostics.append(.warning("Config file '\(observed.targetPath.string)': \(error)"))
        }

        let classification: DifferenceClassification
        let diagnostic: String?
        switch observed.state {
        case .matching, .symlinkToSource:
            summary.configsMatching += 1
            classification = .matching
            diagnostic = observed.diagnostic
        case .machineLocal:
            summary.configsSkipped += 1
            classification = .skipped
            diagnostic = "Preserved as machine-local override (not modified)"
        case .excluded:
            summary.configsSkipped += 1
            classification = .skipped
            diagnostic = "Excluded by manifest rule"
        case .changed, .symlinkExternal, .brokenSymlink:
            summary.configsChanged += 1
            classification = .changed
            diagnostic = observed.diagnostic
        case .missing:
            summary.configsMissing += 1
            classification = .missing
            diagnostic = observed.diagnostic
        case .sourceMissing, .sourceOutsideRoot, .unreadable:
            summary.configsUnknown += 1
            classification = .unknown
            diagnostic = observed.diagnostic
        }

        configDifferences.append(ConfigDifference(
            source: observed.sourcePath,
            target: observed.targetPath,
            classification: classification,
            state: observed.state,
            sourceHash: observed.sourceHash,
            targetHash: observed.targetHash,
            diagnostic: diagnostic
        ))
    }

    packageDifferences = stableSorted(packageDifferences) { a, b in
        if a.kind != b.kind { return a.kind < b.kind }
        if a.classification != b.classification { return a.classification < b.classification }
        return byteOrderPrecedes(a.name, b.name)
    }
    configDifferences = stableSorted(configDifferences) { rustPathPrecedes($0.target, $1.target) }

    return StatusReport(
        schemaVersion: manifest.schemaVersion,
        homebrewAvailable: brewResult.available,
        brewVersion: brewResult.brewVersion,
        packageDifferences: packageDifferences,
        configDifferences: configDifferences,
        diagnostics: diagnostics,
        summary: summary
    )
}

/// Stable sort (Rust `sort_by`), independent of the standard library's unspecified stability.
func stableSorted<T>(_ items: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
    items.enumerated()
        .sorted { lhs, rhs in
            if areInIncreasingOrder(lhs.element, rhs.element) { return true }
            if areInIncreasingOrder(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
}
