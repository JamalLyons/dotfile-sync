import Darwin
import Foundation
import System
import Testing

@testable import Core

/// Journal on-disk parity with Rust, resume of a Rust-written journal, safety checks, and the
/// clonefile backup strategy (native change).
@Suite("Journal and backup")
struct JournalBackupTests {
    /// The three-formula plan used by the Rust reference run.
    static func brewPlan() -> Plan {
        var plan = PlanTests.fixedPlan()
        plan.actions = ["alpha", "beta", "gamma"].enumerated().map { index, name in
            PlanAction(
                id: "a-00\(index + 1)", kind: .brewInstallFormula(name: name),
                summary: "brew install \(name)", risk: .low, reversible: false, backup: false
            )
        }
        return plan
    }

    static func failingRunner() -> MockCommandRunner {
        let ok = ApplyTests.output("")
        return MockCommandRunner()
            .withExecutable("brew", "/mock/bin/brew")
            .withResponse("/mock/bin/brew", args: ["install", "alpha"], ok)
            .withResponse("/mock/bin/brew", args: ["install", "beta"], ok)
            .withResponse(
                "/mock/bin/brew", args: ["install", "gamma"],
                .failure(.nonZeroExit(program: "brew", code: 1, stderr: "gamma failed"))
            )
    }

    /// `journal.jsonl` written by Rust `apply_plan` for ``brewPlan()`` at now = 1_700_000_000_123
    /// with gamma failing (throwaway Rust test, not committed).
    static let rustDigest = "8c968bcf71364842bcdc113e4590a7cd8a33fa179b27ece3f4a1b01d383da35a"
    static let rustJournal = """
        {"event":"header","run_id":"r-d840a3b9677331da","plan_digest":"8c968bcf71364842bcdc113e4590a7cd8a33fa179b27ece3f4a1b01d383da35a"}
        {"event":"step","action_id":"a-001","status":"running","at_ms":1700000000123}
        {"event":"step","action_id":"a-001","status":"done","at_ms":1700000000123}
        {"event":"step","action_id":"a-002","status":"running","at_ms":1700000000123}
        {"event":"step","action_id":"a-002","status":"done","at_ms":1700000000123}
        {"event":"step","action_id":"a-003","status":"running","at_ms":1700000000123}
        {"event":"step","action_id":"a-003","status":"failed","error":"Command 'brew' exited with code 1: gamma failed","at_ms":1700000000123}

        """

    @Test func journalAndPlanJsonAreByteIdenticalToRust() throws {
        let tmp = try TempDir()
        let root = FilePath(tmp.path)
        let plan = Self.brewPlan()
        #expect(plan.digest == Self.rustDigest)
        #expect(makeRunId(digest: plan.digest, now: 1_700_000_000_123) == "r-d840a3b9677331da")
        let ctx = ApplyTests.context(Self.failingRunner(), root.appending("b"), root.appending("run"), now: 1_700_000_000_123)
        #expect(throws: ApplyError.self) { try applyPlan(plan, context: ctx) }
        #expect(try ApplyTests.read(root.appending("run/journal.jsonl")) == Self.rustJournal)
        #expect(try ApplyTests.read(root.appending("run/plan.json")) == jsonStringPretty(plan))
    }

    @Test func resumesAJournalWrittenByRust() throws {
        let tmp = try TempDir()
        let runDir = FilePath(tmp.path).appending("run")
        try ensureDir(runDir)
        try syncFile(runDir.appending("journal.jsonl"), bytes: Array(Self.rustJournal.utf8))
        let retry = ApplyTests.installOk(MockCommandRunner().withExecutable("brew", "/mock/bin/brew"), "gamma")
        var seen: [StepRecord] = []
        let ctx = ApplyTests.context(retry, FilePath(tmp.path).appending("b"), runDir, now: 99)
        let journal = try resumeRun(runDir: runDir, plan: Self.brewPlan(), context: ctx, progress: { seen.append($0) })
        #expect(journal.runId == "r-d840a3b9677331da")
        #expect(journal.steps.map(\.status) == [.done, .done, .done])
        #expect(journal.steps[0].atMs == 1_700_000_000_123)
        #expect(seen.map(\.actionId) == ["a-003", "a-003"])
        #expect(seen.map(\.status) == [.running, .done])
        let text = try ApplyTests.read(runDir.appending("journal.jsonl"))
        #expect(text == Self.rustJournal + """
            {"event":"step","action_id":"a-003","status":"running","at_ms":99}
            {"event":"step","action_id":"a-003","status":"done","at_ms":99}

            """)
    }

    @Test func interruptedRunningStepIsRetriedOnResume() throws {
        // Journal cut off after `a-002` started: the latest record for a-002 is `running`.
        let tmp = try TempDir()
        let runDir = FilePath(tmp.path).appending("run")
        let lines = Self.rustJournal.split(separator: "\n").prefix(4).joined(separator: "\n") + "\n"
        try ensureDir(runDir)
        try syncFile(runDir.appending("journal.jsonl"), bytes: Array(lines.utf8))
        let runner = ApplyTests.installOk(
            ApplyTests.installOk(MockCommandRunner().withExecutable("brew", "/mock/bin/brew"), "beta"), "gamma"
        )
        let ctx = ApplyTests.context(runner, FilePath(tmp.path).appending("b"), runDir, now: 7)
        var seen: [String] = []
        let journal = try resumeRun(runDir: runDir, plan: Self.brewPlan(), context: ctx, progress: { seen.append($0.actionId) })
        #expect(journal.steps.map(\.status) == [.done, .done, .done])
        #expect(seen == ["a-002", "a-002", "a-003", "a-003"])
    }

    @Test func resumeRejectsDigestMismatch() throws {
        let tmp = try TempDir()
        let runDir = FilePath(tmp.path).appending("run")
        try ensureDir(runDir)
        try syncFile(runDir.appending("journal.jsonl"), bytes: Array(Self.rustJournal.utf8))
        var plan = Self.brewPlan()
        plan.stateFingerprint = "changed"
        let ctx = ApplyTests.context(MockCommandRunner(), FilePath(tmp.path).appending("b"), runDir, now: 1)
        #expect(throws: ApplyError.digestMismatch(found: Self.rustDigest, expected: plan.digest)) {
            try resumeRun(runDir: runDir, plan: plan, context: ctx)
        }
        #expect(ApplyError.digestMismatch(found: "a", expected: "b").description
            == "plan digest mismatch: journal has a, plan is b")
    }

    @Test func journalErrors() throws {
        let tmp = try TempDir()
        let runDir = FilePath(tmp.path).appending("run")
        #expect(throws: ApplyError.journal("journal not found at '\(runDir.string)/journal.jsonl'")) {
            try JournalStore.open(runDir: runDir)
        }
        try ensureDir(runDir)
        try syncFile(runDir.appending("journal.jsonl"), bytes: Array("\n{\"event\":\"step\",\"action_id\":\"a\",\"status\":\"done\",\"at_ms\":1}\n".utf8))
        #expect(throws: ApplyError.journal("journal is missing a header")) {
            try JournalStore.open(runDir: runDir).load()
        }
        try syncFile(runDir.appending("journal.jsonl"), bytes: Array("not json\n".utf8))
        do {
            _ = try JournalStore.open(runDir: runDir).load()
            Issue.record("expected invalid line")
        } catch {
            // Not `catch let ApplyError.journal(…)`: crashes the Xcode 26 SIL ownership verifier.
            guard case let .journal(message) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(message.hasPrefix("invalid journal line 1: "))
        }
        // A second apply into the same run dir must refuse to start over.
        let ctx = ApplyTests.context(MockCommandRunner(), FilePath(tmp.path).appending("b"), runDir, now: 1)
        #expect(throws: ApplyError.journal(
            "journal already exists at '\(runDir.string)/journal.jsonl'; resume it instead of starting a new run"
        )) {
            try applyPlan(Self.brewPlan(), context: ctx)
        }
    }

    @Test func cancellationReturnsSnapshotWithoutRunning() throws {
        let tmp = try TempDir()
        let root = FilePath(tmp.path)
        let ctx = ApplyTests.context(MockCommandRunner(), root.appending("b"), root.appending("run"), now: 5)
        do {
            _ = try applyPlan(Self.brewPlan(), context: ctx, isCancelled: { true })
            Issue.record("expected cancellation")
        } catch {
            // Not `catch let ApplyError.cancelled(…)`: crashes the Xcode 26 SIL ownership verifier.
            guard case let .cancelled(journal) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(journal.steps.map(\.status) == [.pending, .pending, .pending])
            #expect(journal.planDigest == Self.rustDigest)
        }
        let text = try ApplyTests.read(root.appending("run/journal.jsonl"))
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test func excludedTargetIsRefusedAtApplyTime() throws {
        let tmp = try TempDir()
        let repo = tmp.url.appendingPathComponent("repo")
        let manifest = try ApplyTests.manifestWith(repo, """
            schema_version = 1
            [exclusions]
            patterns = ["*token*"]

            """)
        let home = FilePath(tmp.path).appending("home")
        let source = FilePath(repo.path).appending("src")
        try syncFile(source, bytes: Array("x".utf8))
        let plan = Plan(
            schema: 1, profile: nil, manifestPath: manifest, home: home, repoRoot: FilePath(repo.path),
            actions: [PlanAction(
                id: "a-001", kind: .copyFile(source: source, target: home.appending("my-token")),
                summary: "copy", risk: .low, reversible: true, backup: false
            )],
            stateFingerprint: "f"
        )
        let ctx = ApplyTests.context(MockCommandRunner(), FilePath(tmp.path).appending("b"), FilePath(tmp.path).appending("run"), now: 1)
        #expect(throws: ApplyError.stepFailed(
            actionId: "a-001",
            message: "refusing to replace excluded path '\(home.string)/my-token'",
            journal: RunJournal(
                runId: makeRunId(digest: plan.digest, now: 1), planDigest: plan.digest,
                steps: [StepRecord(actionId: "a-001", status: .failed,
                                   error: "refusing to replace excluded path '\(home.string)/my-token'", atMs: 1)]
            )
        )) {
            try applyPlan(plan, context: ctx)
        }
        #expect(!pathPresent(home.appending("my-token")))
    }

    @Test func stepRecordJSONOmitsNilFields() throws {
        let full = StepRecord(actionId: "a-1", status: .done, backupPath: "/b", error: "e", atMs: 3, previousShell: "/bin/zsh")
        #expect(try jsonStringCompact(full)
            == #"{"action_id":"a-1","status":"done","backup_path":"/b","error":"e","at_ms":3,"previous_shell":"/bin/zsh"}"#)
        #expect(try jsonStringCompact(StepRecord(actionId: "a", status: .pending, atMs: 0))
            == #"{"action_id":"a","status":"pending","at_ms":0}"#)
    }

    // MARK: - Backups

    @Test func formatStampMatchesRust() {
        #expect(formatStamp(1_700_000_000_000) == "20231114_221320")
        #expect(formatStamp(0) == "19700101_000000")
        #expect(formatStamp(951_782_400_000) == "20000229_000000")
    }

    @Test func relativeToHomeStripsHomeOrKeepsNormalComponents() {
        #expect(relativeToHome(home: "/h", target: "/h/.config/a") == FilePath(".config/a"))
        #expect(relativeToHome(home: "/h", target: "/elsewhere/x") == FilePath("elsewhere/x"))
    }

    private static func writeOriginal(_ root: FilePath, mode: mode_t) throws -> FilePath {
        let target = root.appending("home/.config/app.conf")
        try syncFile(target, bytes: Array("original\n".utf8))
        #expect(target.withPlatformString { chmod($0, mode) } == 0)
        return target
    }

    @Test func backupUsesClonefileOnAPFS() throws {
        let tmp = try TempDir()
        let root = FilePath(tmp.path)
        let target = try Self.writeOriginal(root, mode: 0o640)
        let (dest, strategy) = try backupExisting(
            home: root.appending("home"), backupRoot: root.appending("backups"), runId: "r-1",
            target: target, nowMs: 1_700_000_000_000, ops: .system
        )
        // The temp dir is on the APFS system volume on macOS.
        #expect(strategy == .cloned)
        #expect(dest == root.appending("backups/r-1/.config/app.conf.backup.20231114_221320"))
        #expect(try ApplyTests.read(dest) == "original\n")
        #expect(fileMode(dest) == 0o640)
        #expect(!pathPresent(target))
    }

    @Test func backupFallsBackToRenameWhenCloneUnsupported() throws {
        let tmp = try TempDir()
        let root = FilePath(tmp.path)
        let target = try Self.writeOriginal(root, mode: 0o600)
        let ops = BackupFileOps(clone: { _, _ in ENOTSUP }, rename: BackupFileOps.system.rename)
        let (dest, strategy) = try backupExisting(
            home: root.appending("home"), backupRoot: root.appending("backups"), runId: "r-1",
            target: target, nowMs: 0, ops: ops
        )
        #expect(strategy == .renamed)
        #expect(try ApplyTests.read(dest) == "original\n")
        #expect(fileMode(dest) == 0o600)
        #expect(!pathPresent(target))
    }

    @Test func backupFallsBackToCopyAcrossVolumes() throws {
        let tmp = try TempDir()
        let root = FilePath(tmp.path)
        let target = try Self.writeOriginal(root, mode: 0o751)
        let ops = BackupFileOps(clone: { _, _ in EXDEV }, rename: { _, _ in EXDEV })
        let (dest, strategy) = try backupExisting(
            home: root.appending("home"), backupRoot: root.appending("backups"), runId: "r-1",
            target: target, nowMs: 0, ops: ops
        )
        #expect(strategy == .copied)
        #expect(try ApplyTests.read(dest) == "original\n")
        #expect(fileMode(dest) == 0o751)
        #expect(!pathPresent(target))
    }

    @Test func backupRenameErrorUsesRustMessage() throws {
        let tmp = try TempDir()
        let root = FilePath(tmp.path)
        let target = try Self.writeOriginal(root, mode: 0o644)
        let ops = BackupFileOps(clone: { _, _ in ENOTSUP }, rename: { _, _ in EACCES })
        let dest = root.appending("backups/r-1/.config/app.conf.backup.19700101_000000")
        #expect(throws: ApplyIOError(
            "failed to back up '\(target.string)' to '\(dest.string)': Permission denied (os error 13)"
        )) {
            try backupExisting(
                home: root.appending("home"), backupRoot: root.appending("backups"), runId: "r-1",
                target: target, nowMs: 0, ops: ops
            )
        }
        #expect(pathPresent(target))
    }

    @Test func backupOfSymlinkClonesTheLinkItself() throws {
        let tmp = try TempDir()
        let root = FilePath(tmp.path)
        let target = root.appending("home/.zshrc")
        try ensureDir(root.appending("home"))
        #expect(target.withPlatformString { symlink("/nonexistent/zshrc", $0) } == 0)
        let (dest, strategy) = try backupExisting(
            home: root.appending("home"), backupRoot: root.appending("backups"), runId: "r",
            target: target, nowMs: 0, ops: .system
        )
        #expect(strategy == .cloned)
        #expect(try readLink(dest) == FilePath("/nonexistent/zshrc"))
        #expect(!pathPresent(target))
    }

    @Test func writeAtomicSetsModeAndReplaces() throws {
        let tmp = try TempDir()
        let target = FilePath(tmp.path).appending("a/b/file")
        try writeAtomic(target, bytes: Array("one".utf8), mode: 0o600)
        try writeAtomic(target, bytes: Array("two".utf8), mode: 0o755)
        #expect(try ApplyTests.read(target) == "two")
        #expect(fileMode(target) == 0o755)
        #expect(!pathPresent(FilePath(tmp.path).appending("a/b/file.tmp")))
    }
}
