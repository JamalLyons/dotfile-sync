import Foundation
import System
import Testing

@testable import Core

/// `compare_status` assertions from crates/dotfilesync-core/tests/discovery_and_comparison_tests.rs.
/// Discovery-only assertions live in Discovery/BrewDiscoveryTests.swift.
@Suite("Status comparison")
struct ComparisonTests {
    private static let brew = "/mock/bin/brew"

    private static func ok(_ stdout: String) -> Result<CommandOutput, RunnerError> {
        .success(CommandOutput(statusCode: 0, stdout: stdout, stderr: ""))
    }

    private static func baseRunner() -> MockCommandRunner {
        MockCommandRunner()
            .withExecutable("brew", FilePath(brew))
            .withResponse(brew, args: ["--version"], ok("Homebrew 4.2.0\n"))
    }

    private static func manifest(formulae: [String], casks: [String]) -> Manifest {
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.packageManagers = PackageManagersSection(homebrew: HomebrewSection(formulae: formulae, casks: casks))
        return manifest
    }

    // Ports test_absent_homebrew_produces_diagnostic_not_missing_packages (comparison part)
    @Test func absentHomebrewMarksPackagesUnknown() {
        let disc = discoverHomebrew(MockCommandRunner())
        let report = compareStatus(Self.manifest(formulae: ["git", "fish"], casks: ["ghostty"]),
                                   brewResult: disc, configs: [])
        #expect(report.summary.packagesMissing == 0)
        #expect(report.summary.packagesUnknown == 3)
        for p in report.packageDifferences {
            #expect(p.classification == .unknown)
            #expect(p.installed == nil)
            #expect(p.diagnostic != nil)
        }
    }

    // Ports test_failed_query_and_fallback_marks_packages_as_unknown (comparison part)
    @Test func failedQueryAndFallbackMarksPackagesUnknown() throws {
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"],
                          .failure(.nonZeroExit(program: "brew", code: 1, stderr: "Database corrupted")))
            .withResponse(Self.brew, args: ["list", "--versions", "--formula"],
                          .failure(.nonZeroExit(program: "brew", code: 1, stderr: "Cannot list formulae")))
        let disc = discoverHomebrew(runner)
        #expect(disc.available)
        #expect(!disc.packagesEnumerated)
        let report = compareStatus(Self.manifest(formulae: ["git"], casks: ["ghostty"]), brewResult: disc, configs: [])
        #expect(report.summary.packagesMissing == 0)
        #expect(report.summary.packagesUnknown == 2)
        for p in report.packageDifferences {
            #expect(p.classification == .unknown)
            #expect(p.installed == nil)
            #expect(try #require(p.diagnostic).contains("enumeration failed"))
        }
    }

    // Ports test_malformed_and_unexpected_json_triggers_fallback (no compare_status assertions in
    // Rust; checks the fallback inventory compares as matching)
    @Test func malformedJSONFallbackInventoryCompares() {
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"],
                          Self.ok(#"{"error": "unexpected output structure"}"#))
            .withResponse(Self.brew, args: ["list", "--versions", "--formula"], Self.ok("git 2.45.0\n"))
            .withResponse(Self.brew, args: ["list", "--versions", "--cask"], Self.ok("ghostty 1.0.0\n"))
        let disc = discoverHomebrew(runner)
        let report = compareStatus(Self.manifest(formulae: ["git"], casks: ["ghostty"]), brewResult: disc, configs: [])
        #expect(report.summary.packagesMatching == 2)
        #expect(report.summary.packagesUnknown == 0)
    }

    // Ports test_valid_empty_inventory_is_distinguished_and_enumerated (comparison part)
    @Test func validEmptyInventoryMarksPackagesMissing() {
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"],
                          Self.ok(#"{"formulae": [], "casks": []}"#))
        let disc = discoverHomebrew(runner)
        let report = compareStatus(Self.manifest(formulae: ["git"], casks: ["ghostty"]), brewResult: disc, configs: [])
        #expect(report.summary.packagesMissing == 2)
        #expect(report.summary.packagesUnknown == 0)
        for p in report.packageDifferences {
            #expect(p.classification == .missing)
            #expect(p.installed == false)
        }
    }

    // Ports test_command_timeout_triggers_fallback (no compare_status assertions in Rust; checks
    // the fallback inventory compares as matching)
    @Test func timeoutFallbackInventoryCompares() {
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"],
                          .failure(.timeout(program: "brew", timeout: .seconds(15))))
            .withResponse(Self.brew, args: ["list", "--versions", "--formula"], Self.ok("git 2.45.0\nfish 3.7.0\n"))
            .withResponse(Self.brew, args: ["list", "--versions", "--cask"], Self.ok("ghostty 1.0.0\n"))
        let disc = discoverHomebrew(runner)
        let report = compareStatus(Self.manifest(formulae: ["git", "fish"], casks: ["ghostty"]),
                                   brewResult: disc, configs: [])
        #expect(report.summary.packagesMatching == 3)
        #expect(report.brewVersion == "Homebrew 4.2.0")
        #expect(report.packageDifferences.map(\.name) == ["fish", "git", "ghostty"])
    }

    // Ports test_package_comparison_matching_missing_unmanaged
    @Test func packageComparisonMatchingMissingUnmanaged() throws {
        let runner = Self.baseRunner()
            .withResponse(Self.brew, args: ["info", "--json=v2", "--installed"], Self.ok("""
                {
                    "formulae": [
                        {"name": "git", "installed": [{"version": "2.44.0"}]},
                        {"name": "unmanaged-tool", "installed": [{"version": "1.0.0"}]}
                    ],
                    "casks": [
                        {"token": "ghostty", "version": "0.9.0"}
                    ]
                }
                """))
        let disc = discoverHomebrew(runner)
        #expect(disc.available)
        #expect(disc.packagesEnumerated)
        let report = compareStatus(Self.manifest(formulae: ["git", "ripgrep"], casks: ["ghostty", "zed"]),
                                   brewResult: disc, configs: [])
        #expect(report.summary.packagesMatching == 2)
        #expect(report.summary.packagesMissing == 2)
        #expect(report.summary.packagesUnmanaged == 1)
        #expect(report.summary.packagesUnknown == 0)

        let git = try #require(report.packageDifferences.first { $0.name == "git" })
        #expect(git.classification == .matching)
        #expect(git.installed == true)
        #expect(git.observedVersion == "2.44.0")

        let rg = try #require(report.packageDifferences.first { $0.name == "ripgrep" })
        #expect(rg.classification == .missing)
        #expect(rg.installed == false)
        #expect(rg.observedVersion == nil)

        let unmanaged = try #require(report.packageDifferences.first { $0.name == "unmanaged-tool" })
        #expect(unmanaged.classification == .unmanaged)
        #expect(unmanaged.installed == true)
        #expect(unmanaged.observedVersion == "1.0.0")
    }

    @Test func configDifferencesSortByComponentPathAndWarnOnUnknown() {
        let configs = [
            ObservedConfigFile(sourcePath: "/r/b", targetPath: "/h/b", state: .sourceMissing, diagnostic: "gone"),
            ObservedConfigFile(sourcePath: "/r/a", targetPath: "/h//a", state: .matching),
        ]
        let report = compareStatus(Manifest(schemaVersion: 1), brewResult: BrewDiscoveryResult(), configs: configs)
        #expect(report.configDifferences.map(\.target.string) == ["/h/a", "/h/b"])
        #expect(report.diagnostics.last == .warning("Config file '/h/b': gone"))
        #expect(report.summary.configsUnknown == 1)
    }

    @Test func classificationOrderMatchesDeclaration() {
        #expect(DifferenceClassification.allCases.sorted() == [.matching, .missing, .changed, .unmanaged, .unknown, .skipped])
    }
}
