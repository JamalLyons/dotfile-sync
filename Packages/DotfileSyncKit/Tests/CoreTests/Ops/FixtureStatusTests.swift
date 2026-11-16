import Foundation
import System
import Testing

@testable import Core

/// Port of crates/dotfilesync-core/tests/fixture_status_tests.rs, plus a comparison of the
/// produced JSON against fixtures/example_status_output.json.
@Suite("Fixture status")
struct FixtureStatusTests {
    static func fixtureRunner() -> MockCommandRunner {
        let brew = "/usr/local/bin/brew"
        return MockCommandRunner()
            .withExecutable("brew", FilePath(brew))
            .withResponse(brew, args: ["--version"],
                          .success(CommandOutput(statusCode: 0, stdout: "Homebrew 4.3.0\n", stderr: "")))
            .withResponse(brew, args: ["info", "--json=v2", "--installed"],
                          .success(CommandOutput(statusCode: 0, stdout: """
                              {
                                  "formulae": [
                                      {"name": "git", "installed": [{"version": "2.44.0"}]},
                                      {"name": "unmanaged-cli", "installed": [{"version": "0.5.1"}]}
                                  ],
                                  "casks": [
                                      {"token": "ghostty", "version": "1.0.0"}
                                  ]
                              }
                              """, stderr: "")))
    }

    /// Creates the repo sources and home targets used by the Rust fixture test.
    static func populate(repo: String, home: String) throws {
        func write(_ path: String, _ content: String) throws {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: URL(fileURLWithPath: path))
        }
        try write("\(repo)/sample_config.fish", "# Repo template config\nset -gx MY_ENV production\n")
        try write("\(repo)/sample_matching.conf", "# Static matching config\nenabled = true\n")
        try write("\(repo)/sample_missing.conf", "# Config that will be missing on machine\n")
        let target = "\(home)/.config/sample"
        try write("\(target)/sample_config.fish", "# Local drifted config\nset -gx MY_ENV local_dev_override\n")
        try write("\(target)/sample_matching.conf", "# Static matching config\nenabled = true\n")
        try write("\(target)/local.conf", "# Machine local private settings\nSECRET=local_only\n")
    }

    private static func fixtureReport(repo: TempDir, home: TempDir) throws -> StatusReport {
        let manifest = try loadManifest(TestPaths.fixture("sample_manifest.toml").path)
        let disc = discoverHomebrew(fixtureRunner())
        #expect(disc.available)
        try populate(repo: repo.path, home: home.path)
        let inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: manifest.exclusions, overrides: manifest.overrides)
        return compareStatus(manifest, brewResult: disc, configs: inspector.inspectFiles(manifest.files))
    }

    // Ports test_fixture_status_missing_packages_and_changed_config
    @Test func fixtureStatusMissingPackagesAndChangedConfig() throws {
        let repo = try TempDir(), home = try TempDir()
        let report = try Self.fixtureReport(repo: repo, home: home)

        #expect(report.summary.packagesMatching == 2)
        #expect(report.summary.packagesMissing == 3)
        #expect(report.summary.packagesUnmanaged == 1)
        #expect(report.summary.configsMatching == 1)
        #expect(report.summary.configsChanged == 1)
        #expect(report.summary.configsMissing == 1)
        #expect(report.summary.configsSkipped == 1)

        let missingFormulae = report.packageDifferences
            .filter { $0.classification == .missing && $0.kind == .formula }.map(\.name)
        #expect(missingFormulae.contains("missing-formula-tool"))
        #expect(missingFormulae.contains("ripgrep"))
        let missingCasks = report.packageDifferences
            .filter { $0.classification == .missing && $0.kind == .cask }.map(\.name)
        #expect(missingCasks.contains("missing-gui-app"))

        let changed = try #require(report.configDifferences.first { $0.classification == .changed })
        #expect(rustPathEndsWith(changed.target, "sample_config.fish"))
        #expect(changed.sourceHash != changed.targetHash)

        let local = try #require(report.configDifferences.first { $0.classification == .skipped })
        #expect(rustPathEndsWith(local.target, "local.conf"))
        #expect(local.sourceHash == nil)
        #expect(local.targetHash == nil)

        // Rust writes the pretty JSON to a temp file and checks it exists.
        let out = try TempDir()
        let outPath = "\(out.path)/status_test_output.json"
        try Data(try jsonStringPretty(report).utf8).write(to: URL(fileURLWithPath: outPath))
        #expect(FileManager.default.fileExists(atPath: outPath))
    }

    /// The Rust test does not compare against fixtures/example_status_output.json. Here the
    /// machine-specific absolute prefixes are normalised (`<repo>/` removed from `source`,
    /// `<home>` replaced by `~` in `target`) and the result compared with the fixture.
    ///
    /// The sample manifest lists `~/.config/sample/local.conf` under `[exclusions] paths`, so
    /// exclusion wins over the machine-local override and it is reported as `excluded`.
    @Test func statusJSONMatchesExampleFixture() throws {
        let repo = try TempDir(), home = try TempDir()
        var report = try Self.fixtureReport(repo: repo, home: home)
        let repoPrefix = repo.path + "/"
        for index in report.configDifferences.indices {
            let source = report.configDifferences[index].source.string
            let target = report.configDifferences[index].target.string
            #expect(source.hasPrefix(repoPrefix))
            #expect(target.hasPrefix(home.path))
            report.configDifferences[index].source = FilePath(String(source.dropFirst(repoPrefix.count)))
            report.configDifferences[index].target = FilePath("~" + target.dropFirst(home.path.count))
        }

        let local = try #require(report.configDifferences.first { $0.target == "~/.config/sample/local.conf" })
        #expect(local.state == .excluded)
        #expect(local.diagnostic == "Excluded by manifest rule")

        let fixtureText = try String(contentsOf: TestPaths.fixture("example_status_output.json"), encoding: .utf8)

        let produced = try jsonStringPretty(report)
        // Semantic equality, as JSON values.
        let lhs = try JSONSerialization.jsonObject(with: Data(produced.utf8)) as? NSDictionary
        let rhs = try JSONSerialization.jsonObject(with: Data(fixtureText.utf8)) as? NSDictionary
        #expect(lhs != nil && lhs == rhs)
        // Byte equality with serde_json pretty output (the fixture file adds a trailing newline).
        #expect(produced + "\n" == fixtureText)
    }
}
