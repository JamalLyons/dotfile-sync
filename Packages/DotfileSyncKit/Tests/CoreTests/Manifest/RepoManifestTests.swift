import Core
import Foundation
import Testing

/// Ports of crates/dotfilesync-core/tests/repo_manifest_tests.rs (reads repo-root dotfilesync.toml).
struct RepoManifestTests {
    private static let games = ["melonds", "minecraft", "roblox", "steam"]

    private func manifestText() throws -> String {
        try String(contentsOf: TestPaths.repoRoot.appendingPathComponent("dotfilesync.toml"), encoding: .utf8)
    }

    private func resolved(_ selection: ProfileSelection, _ hostname: String) throws -> ResolvedManifest {
        let manifest = try parseManifest(manifestText())
        return try resolveProfile(manifest, selection: selection, hostname: hostname, os: .macos)
    }

    // Ports Rust test: repo_manifest_tests::repo_manifest_parses
    @Test func repoManifestParses() throws {
        let manifest = try parseManifest(manifestText())
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.setup.loginShell == "fish")
        #expect(manifest.setup.fisher)
        #expect(manifest.select.default == "personal")
        #expect(manifest.select.hostnames["work-mac"] == "work")
        #expect(manifest.profiles["personal"] != nil)
        #expect(manifest.profiles["work"] != nil)
        #expect(manifest.profiles["work"]?.packageManagers.homebrew.excludeCasks == Self.games)
    }

    // Ports Rust test: repo_manifest_tests::personal_matches_base_and_work_drops_games
    @Test func personalMatchesBaseAndWorkDropsGames() throws {
        let personal = try resolved(.explicit("personal"), "host")
        let work = try resolved(.explicit("work"), "host")
        let base = try resolved(.baseOnly, "work-mac")

        #expect(personal.profile == "personal")
        #expect(work.profile == "work")
        #expect(base.profile == nil)

        #expect(personal.homebrew.formulae == base.homebrew.formulae)
        #expect(personal.homebrew.casks == base.homebrew.casks)
        #expect(!personal.homebrew.formulae.contains("awscli"))
        #expect(!personal.homebrew.casks.contains("slack"))

        #expect(work.homebrew.formulae.contains("awscli"))
        #expect(work.homebrew.formulae.count == personal.homebrew.formulae.count + 1)
        #expect(work.homebrew.casks.contains("slack"))
        #expect(work.homebrew.casks.contains("font-0xproto"))
        #expect(work.homebrew.casks.count == personal.homebrew.casks.count - Self.games.count + 1)

        for game in Self.games {
            #expect(personal.homebrew.casks.contains(game), "\(game) should stay on the personal profile")
            #expect(base.homebrew.casks.contains(game), "\(game) should stay on the base layer")
            #expect(!work.homebrew.casks.contains(game), "\(game) should be excluded from the work profile")
        }

        for layer in [personal, work, base] {
            #expect(layer.setup.fisher)
            #expect(layer.setup.loginShell == "fish")
            #expect(layer.overrides.contains { $0.target == "~/.config/fish/conf.d/local.fish" })
        }

        let personalTargets = personal.files.map(\.target)
        let workTargets = work.files.map(\.target)
        let baseTargets = base.files.map(\.target)
        // Rust `is_sorted` on &str compares UTF-8 bytes.
        #expect(zip(personalTargets, personalTargets.dropFirst()).allSatisfy { !$1.utf8.lexicographicallyPrecedes($0.utf8) })
        #expect(personalTargets == baseTargets)
        #expect(workTargets == baseTargets)
        #expect(personalTargets.contains("~/.config/fish/conf.d/fnm.fish"))
        #expect(personalTargets.allSatisfy { !$0.hasSuffix("local.fish") })
    }

    // Ports Rust test: repo_manifest_tests::auto_uses_default_personal_and_hostname_work
    @Test func autoUsesDefaultPersonalAndHostnameWork() throws {
        let fallback = try resolved(.auto, "unmatched-host")
        #expect(fallback.profile == "personal")
        #expect(fallback.homebrew.casks.contains("steam"))

        let mapped = try resolved(.auto, "Work-Mac.local")
        #expect(mapped.profile == "work")
        #expect(!mapped.homebrew.casks.contains("steam"))
        #expect(mapped.homebrew.formulae.contains("awscli"))
    }
}
