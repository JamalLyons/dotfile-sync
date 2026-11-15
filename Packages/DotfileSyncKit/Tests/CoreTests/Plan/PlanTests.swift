import Foundation
import System
import Testing

@testable import Core

/// Port of crates/dotfilesync-core/tests/plan_tests.rs, plus digest parity with Rust.
@Suite("Plan")
struct PlanTests {
    static func brewRunner(_ json: String) -> MockCommandRunner {
        let brew = "/mock/bin/brew"
        return MockCommandRunner()
            .withExecutable("brew", FilePath(brew))
            .withResponse(
                brew, args: ["--version"],
                .success(CommandOutput(statusCode: 0, stdout: "Homebrew 4.2.0\n", stderr: ""))
            )
            .withResponse(
                brew, args: ["info", "--json=v2", "--installed"],
                .success(CommandOutput(statusCode: 0, stdout: json, stderr: ""))
            )
    }

    static func writeFixture(_ root: URL) throws -> FilePath {
        let fm = FileManager.default
        let repo = root.appendingPathComponent("repo")
        let home = root.appendingPathComponent("home")
        try fm.createDirectory(at: repo.appendingPathComponent("config"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".config"), withIntermediateDirectories: true)
        try "desired\n".write(to: repo.appendingPathComponent("config/app.conf"), atomically: false, encoding: .utf8)
        try "original\n".write(to: home.appendingPathComponent(".config/app.conf"), atomically: false, encoding: .utf8)
        let manifest = repo.appendingPathComponent("dotfilesync.toml")
        try """

            schema_version = 1

            [package_managers.homebrew]
            formulae = ["git"]

            [[files]]
            source = "config/app.conf"
            target = "~/.config/app.conf"
            mode = "copy"

            """.write(to: manifest, atomically: false, encoding: .utf8)
        return FilePath(manifest.path)
    }

    // Rust: two_plan_runs_produce_identical_json
    @Test func twoPlanRunsProduceIdenticalJson() throws {
        let tmp = try TempDir()
        let manifest = try Self.writeFixture(tmp.url)
        let home = FilePath(tmp.path).appending("home")
        let runner = Self.brewRunner(
            #"{"formulae":[{"name":"git","installed":[{"version":"2.45.0"}]}],"casks":[]}"#
        )
        let input = PlanInput(
            manifest: manifest, home: home, repoRoot: FilePath(tmp.path).appending("repo"), profile: nil
        )
        let first = try runPlan(input, runner: runner, hostname: "test-host")
        let second = try runPlan(input, runner: runner, hostname: "test-host")
        #expect(try jsonStringCompact(first) == jsonStringCompact(second))
        #expect(first.digest == second.digest)
        #expect(first.planId == "p-" + first.digest.prefix(16))
        #expect(first.schema == PLAN_SCHEMA)
        #expect(!first.isEmpty)
        #expect(first.actions.contains { $0.backup })
    }

    /// A plan covering every `ActionKind` variant, `Some`/`None` options, escapes and non-ASCII.
    static func fixedPlan() -> Plan {
        func a(_ id: String, _ kind: ActionKind, _ summary: String, _ risk: Risk, _ rev: Bool, _ backup: Bool) -> PlanAction {
            PlanAction(id: id, kind: kind, summary: summary, risk: risk, reversible: rev, backup: backup)
        }
        return Plan(
            schema: PLAN_SCHEMA,
            profile: "work",
            manifestPath: "/fixed/repo/dotfilesync.toml",
            home: "/fixed/home",
            repoRoot: "/fixed/repo",
            actions: [
                a("a-001", .brewInstallFormula(name: "git"), "brew install git", .low, false, false),
                a("a-002", .brewInstallCask(name: "wezterm"), "brew install --cask wezterm", .medium, false, false),
                a("a-003", .copyFile(source: "/fixed/repo/config/app.conf", target: "/fixed/home/.config/app.conf"),
                  "copy /fixed/repo/config/app.conf -> /fixed/home/.config/app.conf", .medium, true, true),
                a("a-004", .linkFile(source: "/fixed/repo/zshrc", target: "/fixed/home/.zshrc"),
                  "link /fixed/repo/zshrc -> /fixed/home/.zshrc", .low, true, false),
                a("a-005", .ensureLocalOverride(target: "/fixed/home/.config/fish/conf.d/local.fish", template: nil),
                  "ensure local override /fixed/home/.config/fish/conf.d/local.fish", .low, true, false),
                a("a-006", .ensureLocalOverride(target: "/fixed/home/.gitconfig.local", template: "/fixed/repo/git/local \"tpl\"\tü"),
                  "ensure local override /fixed/home/.gitconfig.local", .low, true, false),
                a("a-007", .installFisher, "install fisher", .medium, false, false),
                a("a-008", .fisherUpdate, "fisher update", .medium, false, false),
                a("a-009", .setLoginShell(shell: "/opt/homebrew/bin/fish"),
                  "set login shell to /opt/homebrew/bin/fish", .high, true, false),
            ],
            stateFingerprint: "0123abcd"
        )
    }

    /// Values printed by `Plan::digest`, `Plan::plan_id` and `serde_json::to_string` in Rust for
    /// the same plan (throwaway Rust test, not committed).
    static let rustDigest = "9bf90c212c193ce8d5020fcb82302693351aef603817937c8fac66a2bd41940f"
    static let rustDigestNoProfile = "b04ebafa6c5cdfa3586bb9f53fcb50e1bc26f57beab9d73974fbb14142d2c150"
    static let rustCompact = #"{"schema":1,"profile":"work","manifest_path":"/fixed/repo/dotfilesync.toml","home":"/fixed/home","repo_root":"/fixed/repo","actions":[{"id":"a-001","kind":{"kind":"brew_install_formula","name":"git"},"summary":"brew install git","risk":"low","reversible":false,"backup":false},{"id":"a-002","kind":{"kind":"brew_install_cask","name":"wezterm"},"summary":"brew install --cask wezterm","risk":"medium","reversible":false,"backup":false},{"id":"a-003","kind":{"kind":"copy_file","source":"/fixed/repo/config/app.conf","target":"/fixed/home/.config/app.conf"},"summary":"copy /fixed/repo/config/app.conf -> /fixed/home/.config/app.conf","risk":"medium","reversible":true,"backup":true},{"id":"a-004","kind":{"kind":"link_file","source":"/fixed/repo/zshrc","target":"/fixed/home/.zshrc"},"summary":"link /fixed/repo/zshrc -> /fixed/home/.zshrc","risk":"low","reversible":true,"backup":false},{"id":"a-005","kind":{"kind":"ensure_local_override","target":"/fixed/home/.config/fish/conf.d/local.fish","template":null},"summary":"ensure local override /fixed/home/.config/fish/conf.d/local.fish","risk":"low","reversible":true,"backup":false},{"id":"a-006","kind":{"kind":"ensure_local_override","target":"/fixed/home/.gitconfig.local","template":"/fixed/repo/git/local \"tpl\"\tü"},"summary":"ensure local override /fixed/home/.gitconfig.local","risk":"low","reversible":true,"backup":false},{"id":"a-007","kind":{"kind":"install_fisher"},"summary":"install fisher","risk":"medium","reversible":false,"backup":false},{"id":"a-008","kind":{"kind":"fisher_update"},"summary":"fisher update","risk":"medium","reversible":false,"backup":false},{"id":"a-009","kind":{"kind":"set_login_shell","shell":"/opt/homebrew/bin/fish"},"summary":"set login shell to /opt/homebrew/bin/fish","risk":"high","reversible":true,"backup":false}],"state_fingerprint":"0123abcd"}"#

    @Test func digestMatchesRust() throws {
        let plan = Self.fixedPlan()
        #expect(try jsonStringCompact(plan) == Self.rustCompact)
        #expect(plan.digest == Self.rustDigest)
        #expect(plan.planId == "p-9bf90c212c193ce8")
        var noProfile = plan
        noProfile.profile = nil
        #expect(noProfile.digest == Self.rustDigestNoProfile)
    }

    @Test func planRoundTripsThroughJSON() throws {
        let plan = Self.fixedPlan()
        let decoded = try JSONDecoder().decode(Plan.self, from: Data(Self.rustCompact.utf8))
        #expect(decoded == plan)
        #expect(decoded.digest == Self.rustDigest)
    }

    @Test func planInputSkipsNilProfile() throws {
        let input = PlanInput(manifest: "/m.toml", home: "/h")
        #expect(try jsonStringCompact(input) == #"{"manifest":"/m.toml","home":"/h","repo_root":null}"#)
        let withProfile = PlanInput(manifest: "/m.toml", home: "/h", repoRoot: "/r", profile: "p")
        #expect(try jsonStringCompact(withProfile) == #"{"manifest":"/m.toml","home":"/h","repo_root":"/r","profile":"p"}"#)
    }

    @Test func cancelledBeforeStartThrows() throws {
        let input = PlanInput(manifest: "/nonexistent.toml", home: "/h")
        #expect(throws: OpError.cancelled) {
            try runPlan(input, runner: MockCommandRunner(), hostname: "h", isCancelled: { true })
        }
    }
}
