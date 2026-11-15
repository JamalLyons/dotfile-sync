import Darwin
import Foundation
import System
import Testing

@testable import Core

/// Port of crates/dotfilesync-core/tests/apply_tests.rs.
@Suite("Apply")
struct ApplyTests {
    static func output(_ stdout: String) -> Result<CommandOutput, RunnerError> {
        .success(CommandOutput(statusCode: 0, stdout: stdout, stderr: ""))
    }

    static func brewBase(_ json: String) -> MockCommandRunner {
        let brew = "/mock/bin/brew"
        return MockCommandRunner()
            .withExecutable("brew", FilePath(brew))
            .withResponse(brew, args: ["--version"], output("Homebrew 4.2.0\n"))
            .withResponse(brew, args: ["info", "--json=v2", "--installed"], output(json))
    }

    static func installOk(_ runner: MockCommandRunner, _ name: String) -> MockCommandRunner {
        runner.withResponse("/mock/bin/brew", args: ["install", name], output(""))
    }

    static func context(
        _ runner: any CommandRunner,
        _ backupRoot: FilePath,
        _ runDir: FilePath,
        allowSudo: Bool = false,
        now: UInt64
    ) -> ApplyContext {
        ApplyContext(runner: runner, backupRoot: backupRoot, runDir: runDir, allowSudo: allowSudo, now: { now })
    }

    static func manifestWith(_ repo: URL, _ body: String) throws -> FilePath {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let path = repo.appendingPathComponent("dotfilesync.toml")
        try body.write(to: path, atomically: false, encoding: .utf8)
        return FilePath(path.path)
    }

    static func mkdirs(_ url: URL, _ sub: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(sub), withIntermediateDirectories: true)
    }

    static func write(_ url: URL, _ sub: String, _ text: String) throws {
        try text.write(to: url.appendingPathComponent(sub), atomically: false, encoding: .utf8)
    }

    static func read(_ path: FilePath) throws -> String {
        try String(contentsOfFile: path.string, encoding: .utf8)
    }

    // Rust: backup_is_created_for_a_differing_file_and_journal_is_written
    @Test func backupIsCreatedForADifferingFileAndJournalIsWritten() throws {
        let tmp = try TempDir()
        let repo = tmp.url.appendingPathComponent("repo")
        let home = tmp.url.appendingPathComponent("home")
        try Self.mkdirs(repo, "config")
        try Self.mkdirs(home, ".config")
        try Self.write(repo, "config/app.conf", "desired\n")
        try Self.write(home, ".config/app.conf", "original\n")
        let manifest = try Self.manifestWith(repo, """

            schema_version = 1
            [[files]]
            source = "config/app.conf"
            target = "~/.config/app.conf"

            """)
        let runner = MockCommandRunner()
        let input = PlanInput(manifest: manifest, home: FilePath(home.path), repoRoot: FilePath(repo.path))
        let plan = try runPlan(input, runner: runner, hostname: "host")
        #expect(plan.actions.count == 1)
        #expect(plan.actions[0].backup)
        guard case .copyFile = plan.actions[0].kind else {
            Issue.record("expected copy_file")
            return
        }

        let backupRoot = FilePath(tmp.path).appending("backups")
        let runDir = FilePath(tmp.path).appending("run")
        let ctx = Self.context(runner, backupRoot, runDir, now: 1_700_000_000_000)
        let journal = try applyPlan(plan, context: ctx)
        #expect(journal.steps.count == 1)
        #expect(journal.steps[0].status == .done)
        #expect(try Self.read(FilePath(home.path).appending(".config/app.conf")) == "desired\n")
        let backup = try #require(journal.steps[0].backupPath)
        #expect(backup.starts(with: backupRoot), "\(backup)")
        #expect(backup.string.contains(".backup."), "\(backup)")
        #expect(try Self.read(backup) == "original\n")
        let journalText = try Self.read(runDir.appending("journal.jsonl"))
        #expect(journalText.contains(plan.actions[0].id))
        #expect(journalText.contains(plan.digest))
        #expect(isRegularFileFollowing(runDir.appending("plan.json")))
    }

    // Rust: resume_skips_completed_steps_after_step_three_fails
    @Test func resumeSkipsCompletedStepsAfterStepThreeFails() throws {
        let tmp = try TempDir()
        let repo = tmp.url.appendingPathComponent("repo")
        let manifest = try Self.manifestWith(repo, """

            schema_version = 1
            [package_managers.homebrew]
            formulae = ["alpha", "beta", "gamma"]

            """)
        let json = #"{"formulae":[],"casks":[]}"#
        let failing = Self.installOk(Self.installOk(Self.brewBase(json), "alpha"), "beta").withResponse(
            "/mock/bin/brew", args: ["install", "gamma"],
            .failure(.nonZeroExit(program: "brew", code: 1, stderr: "gamma failed"))
        )
        let input = PlanInput(
            manifest: manifest, home: FilePath(tmp.path).appending("home"), repoRoot: FilePath(repo.path)
        )
        try FileManager.default.createDirectory(atPath: input.home.string, withIntermediateDirectories: true)
        let plan = try runPlan(input, runner: failing, hostname: "host")
        #expect(plan.actions.count == 3)

        let runDir = FilePath(tmp.path).appending("run")
        let backups = FilePath(tmp.path).appending("backups")
        let ctx = Self.context(failing, backups, runDir, now: 10)
        do {
            _ = try applyPlan(plan, context: ctx)
            Issue.record("expected step failure")
        } catch let ApplyError.stepFailed(actionId, _, journal) {
            #expect(actionId == "a-003")
            #expect(journal.steps[0].status == .done)
            #expect(journal.steps[1].status == .done)
            #expect(journal.steps[2].status == .failed)
        }

        let retry = Self.installOk(MockCommandRunner().withExecutable("brew", "/mock/bin/brew"), "gamma")
        let retryCtx = Self.context(retry, backups, runDir, now: 10)
        let journal = try resumeRun(runDir: runDir, plan: plan, context: retryCtx)
        #expect(journal.steps.allSatisfy { $0.status == .done })
    }

    // Rust: local_fish_is_not_overwritten
    @Test func localFishIsNotOverwritten() throws {
        let tmp = try TempDir()
        let repo = tmp.url.appendingPathComponent("repo")
        let home = tmp.url.appendingPathComponent("home")
        try Self.mkdirs(repo, "fish/conf.d")
        try Self.mkdirs(repo, "config")
        try Self.mkdirs(home, ".config/fish/conf.d")
        try Self.write(repo, "fish/conf.d/local.fish", "from-repo\n")
        try Self.write(repo, "config/app.conf", "desired\n")
        try Self.write(home, ".config/fish/conf.d/local.fish", "SECRET\n")
        let manifest = try Self.manifestWith(repo, """

            schema_version = 1

            [[files]]
            source = "config/app.conf"
            target = "~/.config/app.conf"

            [[files]]
            source = "fish/conf.d/local.fish"
            target = "~/.config/fish/conf.d/local.fish"

            [[overrides]]
            target = "~/.config/fish/conf.d/local.fish"

            """)
        try Self.mkdirs(home, ".config")
        let runner = MockCommandRunner()
        let input = PlanInput(manifest: manifest, home: FilePath(home.path), repoRoot: FilePath(repo.path))
        let plan = try runPlan(input, runner: runner, hostname: "host")
        #expect(!plan.actions.contains { action in
            switch action.kind {
            case let .copyFile(_, target), let .linkFile(_, target):
                return rustPathEndsWith(target, "local.fish")
            default:
                return false
            }
        })
        let ctx = Self.context(runner, FilePath(tmp.path).appending("backups"), FilePath(tmp.path).appending("run"), now: 20)
        _ = try applyPlan(plan, context: ctx)
        #expect(try Self.read(FilePath(home.path).appending(".config/fish/conf.d/local.fish")) == "SECRET\n")
    }

    // Rust: replan_after_apply_is_empty_on_a_converged_fixture
    @Test func replanAfterApplyIsEmptyOnAConvergedFixture() throws {
        let tmp = try TempDir()
        let repo = tmp.url.appendingPathComponent("repo")
        let home = tmp.url.appendingPathComponent("home")
        try Self.mkdirs(repo, "config")
        try Self.write(repo, "config/app.conf", "same\n")
        let manifest = try Self.manifestWith(repo, """

            schema_version = 1
            [package_managers.homebrew]
            formulae = ["git"]
            [[files]]
            source = "config/app.conf"
            target = "~/.config/app.conf"

            """)
        let runner = Self.brewBase(#"{"formulae":[{"name":"git","installed":[{"version":"2.45.0"}]}],"casks":[]}"#)
        let input = PlanInput(manifest: manifest, home: FilePath(home.path), repoRoot: FilePath(repo.path))
        let plan = try runPlan(input, runner: runner, hostname: "host")
        #expect(plan.actions.count == 1)
        let ctx = Self.context(runner, FilePath(tmp.path).appending("backups"), FilePath(tmp.path).appending("run"), now: 30)
        _ = try applyPlan(plan, context: ctx)
        let again = try runPlan(input, runner: runner, hostname: "host")
        #expect(again.isEmpty, "\(again)")
    }

    // Rust: symlink_mode_points_target_at_source
    @Test func symlinkModePointsTargetAtSource() throws {
        let tmp = try TempDir()
        let repo = tmp.url.appendingPathComponent("repo")
        let home = tmp.url.appendingPathComponent("home")
        try Self.mkdirs(repo, "config")
        try Self.write(repo, "config/app.conf", "linked\n")
        let manifest = try Self.manifestWith(repo, """

            schema_version = 1
            [[files]]
            source = "config/app.conf"
            target = "~/.config/app.conf"
            mode = "symlink"

            """)
        let runner = MockCommandRunner()
        let input = PlanInput(manifest: manifest, home: FilePath(home.path), repoRoot: FilePath(repo.path))
        let plan = try runPlan(input, runner: runner, hostname: "host")
        guard case .linkFile = plan.actions[0].kind else {
            Issue.record("expected link_file")
            return
        }
        #expect(!plan.actions[0].backup)
        let ctx = Self.context(runner, FilePath(tmp.path).appending("backups"), FilePath(tmp.path).appending("run"), now: 40)
        _ = try applyPlan(plan, context: ctx)
        let target = FilePath(home.path).appending(".config/app.conf")
        let st = try lstatPath(target).get()
        #expect((st.st_mode & S_IFMT) == S_IFLNK)
        #expect(try readLink(target) == FilePath(repo.path).appending("config/app.conf"))
    }

    // Rust: login_shell_without_sudo_fails_cleanly
    @Test func loginShellWithoutSudoFailsCleanly() throws {
        let tmp = try TempDir()
        let root = FilePath(tmp.path)
        let plan = Plan(
            schema: 1,
            profile: nil,
            manifestPath: root.appending("missing.toml"),
            home: root.appending("home"),
            repoRoot: root.appending("repo"),
            actions: [PlanAction(
                id: "a-001",
                kind: .setLoginShell(shell: "/opt/homebrew/bin/fish-dotfilesync-test"),
                summary: "set login shell",
                risk: .high,
                reversible: true,
                backup: false
            )],
            stateFingerprint: "fingerprint"
        )
        let runner = MockCommandRunner()
        let ctx = Self.context(runner, root.appending("backups"), root.appending("run"), now: 50)
        do {
            _ = try applyPlan(plan, context: ctx)
            Issue.record("expected a failed step")
        } catch let ApplyError.stepFailed(_, message, journal) {
            #expect(message.contains("requires sudo; rerun with --allow-sudo"), "\(message)")
            #expect(journal.steps[0].status == .failed)
            #expect(journal.steps[0].error == "requires sudo; rerun with --allow-sudo")
        }
    }
}
