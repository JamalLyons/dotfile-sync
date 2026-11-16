// Port of crates/dotfilesync-cli/tests/cli_tests.rs. Spawns the built `dotfilesync`.

import Core
import Foundation
import System
import Testing

@Suite struct CLITests {
    @Test func cliHelp() throws {
        let env = try Env()
        try env.cli(["--help"]).success().stdout.contains("dotfilesync inspects, tracks, and safely reports drift")
            .expectTrue()
    }

    @Test func importBrewfileStandard() throws {
        let env = try Env()
        let run = try env.cli(["import-brewfile", "--brewfile", fixture("Brewfile.standard")]).success()
        #expect(run.stdout.contains("Imported 4 formulae and 2 casks statically."))
    }

    @Test func importBrewfileDynamicJSON() throws {
        let env = try Env()
        let run = try env.cli(["import-brewfile", "--brewfile", fixture("Brewfile.dynamic"), "--json"]).success()
        #expect(run.stdout.contains("\"construct_type\": \"dynamic_ruby\""))
        #expect(run.stdout.contains("\"construct_type\": \"tap\""))
    }

    @Test func importBrewfileCreatesOutputAndRefusesOverwrite() throws {
        let env = try Env()
        let output = env.tmp.appending("generated_manifest.toml")
        let args = ["import-brewfile", "--brewfile", fixture("Brewfile.standard"), "--output", output.string]

        let first = try env.cli(args).success()
        #expect(first.stdout.contains("Wrote manifest skeleton to:"))
        #expect(exists(output))
        let initial = try Data(contentsOf: URL(fileURLWithPath: output.string))
        // The skeleton is a loadable manifest with the Brewfile's packages (formatting may differ
        // from the Rust CLI; the content may not).
        let written = try loadManifest(output.string)
        #expect(written.packageManagers.homebrew.formulae == ["bat", "fish", "git", "ripgrep"])
        #expect(written.packageManagers.homebrew.casks == ["ghostty", "zed"])
        #expect(String(decoding: initial, as: UTF8.self).hasSuffix("\n"))

        let second = try env.cli(args).failure()
        #expect(second.stderr.contains("already exists; refusing to overwrite"))
        let after = try Data(contentsOf: URL(fileURLWithPath: output.string))
        #expect(initial == after, "Existing manifest bytes must remain completely unchanged")
    }

    @Test func statusJSONFixtureIsolated() throws {
        let env = try Env()
        let repo = env.tmp.appending("repo")
        try FileManager.default.createDirectory(atPath: repo.string, withIntermediateDirectories: true)
        let run = try env.cli([
            "status", "--manifest", fixture("sample_manifest.toml"), "--home", env.home.string,
            "--repo-root", repo.string, "--brew-bin", env.brew.string, "--json",
        ]).success()
        #expect(run.stdout.contains("\"schema_version\": 1"))
        #expect(run.stdout.contains("\"package_differences\":"))
        #expect(run.stdout.contains("\"config_differences\":"))
        #expect(run.stdout.contains("\"homebrew_available\": true"))
    }

    @Test func scanJSONFixtureIsolated() throws {
        let env = try Env()
        let repo = env.tmp.appending("repo")
        try FileManager.default.createDirectory(atPath: repo.string, withIntermediateDirectories: true)
        let run = try env.cli([
            "scan", "--manifest", fixture("sample_manifest.toml"), "--home", env.home.string,
            "--repo-root", repo.string, "--brew-bin", env.brew.string, "--json",
        ]).success()
        #expect(run.stdout.contains("\"available\": true"))
        #expect(run.stdout.contains("\"packages_enumerated\": true"))
        #expect(run.stdout.contains("\"configs\":"))
    }

    @Test func statusHumanAbsentMachineLocalDistinguishable() throws {
        let env = try Env()
        let repo = env.tmp.appending("repo")
        try FileManager.default.createDirectory(atPath: repo.string, withIntermediateDirectories: true)
        try "ordinary content\n".write(toFile: repo.appending("ordinary.conf").string, atomically: true, encoding: .utf8)
        let manifest = repo.appending("manifest.toml")
        try """

        schema_version = 1

        [[files]]
        source = "ordinary.conf"
        target = "~/.config/ordinary.conf"

        [[files]]
        source = "fish/conf.d/local.fish"
        target = "~/.config/fish/conf.d/local.fish"
        machine_local = true

        """.write(toFile: manifest.string, atomically: true, encoding: .utf8)

        let out = try env.cli([
            "status", "--manifest", manifest.string, "--home", env.home.string,
            "--repo-root", repo.string, "--brew-bin", env.brew.string,
        ]).success().stdout

        #expect(out.contains("MISSING CONFIG FILES (1):"))
        #expect(out.contains("ordinary.conf"))
        #expect(out.contains("ABSENT MACHINE-LOCAL OVERRIDES (not created on this machine) (1):"))
        #expect(out.contains(".config/fish/conf.d/local.fish"))
        #expect(out.contains("intentionally local; no repository restoration required"))
    }

    /// Uses the host's real Homebrew read-only (`--version`, `info`) against a temp HOME and a
    /// controlled manifest, like the Rust test. Skipped when no brew is installed.
    @Test func liveMacOSScanAndStatusControlledFixtures() throws {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            return
        }
        let env = try Env()
        let repo = env.tmp.appending("repo")
        try FileManager.default.createDirectory(atPath: repo.string, withIntermediateDirectories: true)
        let manifest = repo.appending("controlled_manifest.toml")
        try """

        schema_version = 1

        [package_managers.homebrew]
        formulae = ["git"]
        casks = []

        [[files]]
        source = "sample.conf"
        target = "~/.config/sample.conf"

        [exclusions]
        paths = []
        patterns = ["*.backup.*"]

        """.write(toFile: manifest.string, atomically: true, encoding: .utf8)
        try "managed_key = true\n".write(toFile: repo.appending("sample.conf").string, atomically: true, encoding: .utf8)
        let common = ["--manifest", manifest.string, "--home", env.home.string, "--repo-root", repo.string, "--brew-bin", brew, "--json"]

        let scan = try env.cli(["scan"] + common).success().json()
        let homebrew = try #require(scan["homebrew"] as? [String: Any])
        #expect(homebrew["available"] as? Bool == true)
        #expect(homebrew["packages_enumerated"] as? Bool == true)
        #expect(homebrew["brew_version"] is String)
        #expect(homebrew["formulae"] is [Any])
        #expect(homebrew["casks"] is [Any])
        #expect((scan["configs"] as? [Any])?.count == 1)

        let status = try env.cli(["status"] + common).success().json()
        #expect(status["homebrew_available"] as? Bool == true)
        let summary = try #require(status["summary"] as? [String: Any])
        #expect(summary["packages_unknown"] as? Int == 0)
        #expect(summary["configs_missing"] as? Int == 1)
    }
}

extension Bool {
    func expectTrue(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(self, sourceLocation: sourceLocation)
    }
}
