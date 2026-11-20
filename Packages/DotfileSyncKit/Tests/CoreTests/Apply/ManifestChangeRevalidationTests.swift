import Foundation
import System
import Testing

@testable import Core

/// Issue #33: promote/demote revalidate the planned state at apply and on resume.
@Suite("ManifestChangeRevalidation")
struct ManifestChangeRevalidationTests {
    typealias Fixture = ManifestChangeTests.Fixture

    /// Starts a run of `plan` and journals `a-001` as `running` without executing it, as if the
    /// process crashed right after the step started.
    static func crashedRun(_ plan: Plan, _ ctx: ApplyContext) throws {
        try ensureDir(ctx.runDir)
        let store = try JournalStore.create(
            runDir: ctx.runDir, runId: makeRunId(digest: plan.digest, now: 1), planDigest: plan.digest, plan: plan
        )
        try store.appendStep(StepRecord(actionId: plan.actions[0].id, status: .running, atMs: 1))
    }

    /// Runs `body`, expects ``ApplyError/stepFailed(actionId:message:journal:)``, returns its message.
    static func stepFailure(_ body: () throws -> RunJournal) -> String? {
        do {
            _ = try body()
            Issue.record("expected a failed step")
            return nil
        } catch {
            // Not `catch let ApplyError.stepFailed(…)`: crashes the Xcode 26 SIL ownership verifier.
            guard let applyError = error as? ApplyError, case let .stepFailed(_, message, journal) = applyError else {
                Issue.record("unexpected error: \(error)")
                return nil
            }
            #expect(journal.steps.last?.status == .failed)
            return message
        }
    }

    func text(_ path: FilePath) throws -> String {
        try String(contentsOfFile: path.string, encoding: .utf8)
    }

    // MARK: - A33-2a: resume

    @Test func resumeFailsClosedWhenTargetEditedAfterCrash() throws {
        let f = try ManifestChangeTests.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        let ctx = f.context("crash")
        try Self.crashedRun(plan, ctx)
        try f.write(home: ".gitconfig", "[user]\n\tname = edited\n")

        let message = try #require(Self.stepFailure { try resumeRun(runDir: ctx.runDir, plan: plan, context: ctx) })
        #expect(message.contains("changed after the plan was approved"), "\(message)")
        #expect(!pathPresent(f.repoPath.appending("gitconfig")))
        #expect(try f.manifestText() == ManifestChangeTests.manifestBody)
    }

    @Test func resumeFailsClosedWhenTargetEditedAfterPartialCopy() throws {
        let f = try ManifestChangeTests.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        let ctx = f.context("crash")
        try Self.crashedRun(plan, ctx)
        // The copy landed before the crash; the manifest edit did not.
        try "[user]\n".write(toFile: f.repoPath.appending("gitconfig").string, atomically: false, encoding: .utf8)
        try f.write(home: ".gitconfig", "[user]\n\tname = edited\n")

        let message = try #require(Self.stepFailure { try resumeRun(runDir: ctx.runDir, plan: plan, context: ctx) })
        #expect(message.contains("changed after the plan was approved"), "\(message)")
        #expect(try text(f.repoPath.appending("gitconfig")) == "[user]\n")
        #expect(try f.manifestText() == ManifestChangeTests.manifestBody)
    }

    @Test func resumeFailsClosedWhenRepoSourceEditedAfterPartialCopy() throws {
        let f = try ManifestChangeTests.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        let ctx = f.context("crash")
        try Self.crashedRun(plan, ctx)
        try "edited in repo\n".write(toFile: f.repoPath.appending("gitconfig").string, atomically: false, encoding: .utf8)

        let message = try #require(Self.stepFailure { try resumeRun(runDir: ctx.runDir, plan: plan, context: ctx) })
        #expect(message.contains("repository path"), "\(message)")
        #expect(try text(f.repoPath.appending("gitconfig")) == "edited in repo\n")
        #expect(try f.manifestText() == ManifestChangeTests.manifestBody)
    }

    @Test func resumeCompletesUntouchedPartialPromote() throws {
        let f = try ManifestChangeTests.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        let ctx = f.context("crash")
        try Self.crashedRun(plan, ctx)
        try "[user]\n".write(toFile: f.repoPath.appending("gitconfig").string, atomically: false, encoding: .utf8)

        let journal = try resumeRun(runDir: ctx.runDir, plan: plan, context: ctx)
        #expect(journal.steps.map(\.status) == [.done])
        #expect(try text(f.repoPath.appending("gitconfig")) == "[user]\n")
        let parsed = try parseManifest(try f.manifestText())
        #expect(parsed.files.filter { $0.target == "~/.gitconfig" } == [TrackedFile(source: "gitconfig", target: "~/.gitconfig")])
    }

    @Test func resumeCompletesUntouchedPromoteAfterCrashBeforeAnyWrite() throws {
        let f = try ManifestChangeTests.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        let ctx = f.context("crash")
        try Self.crashedRun(plan, ctx)

        let journal = try resumeRun(runDir: ctx.runDir, plan: plan, context: ctx)
        #expect(journal.steps.map(\.status) == [.done])
        #expect(try text(f.repoPath.appending("gitconfig")) == "[user]\n")
    }

    @Test func resumeFailsClosedWhenDemotedEntryReplacedAfterCrash() throws {
        let f = try ManifestChangeTests.fixture()
        let plan = try planManifestChange(f.input(.demote(targets: [f.homeFile(".zshrc")])), hostname: "host")
        let ctx = f.context("crash")
        try Self.crashedRun(plan, ctx)
        let replaced = ManifestChangeTests.manifestBody.replacingOccurrences(of: "zsh/zshrc", with: "zsh/other")
        try replaced.write(toFile: f.manifest.string, atomically: false, encoding: .utf8)

        let message = try #require(Self.stepFailure { try resumeRun(runDir: ctx.runDir, plan: plan, context: ctx) })
        #expect(message.contains("not the planned entry"), "\(message)")
        #expect(try f.manifestText() == replaced)
    }

    @Test func resumeSkipsDemoteWhoseEntryWasAlreadyRemoved() throws {
        let f = try ManifestChangeTests.fixture()
        let plan = try planManifestChange(f.input(.demote(targets: [f.homeFile(".zshrc")])), hostname: "host")
        let ctx = f.context("crash")
        try Self.crashedRun(plan, ctx)
        // The manifest rewrite landed before the crash.
        let edited = try removingTrackedFile(at: 0, from: ManifestChangeTests.manifestBody)
        try edited.write(toFile: f.manifest.string, atomically: false, encoding: .utf8)

        let journal = try resumeRun(runDir: ctx.runDir, plan: plan, context: ctx)
        #expect(journal.steps.map(\.status) == [.skipped])
        #expect(try f.manifestText() == edited)
    }

    // MARK: - A33-2b: demote matches the full entry

    @Test func demoteRefusesEntryReplacedAfterPlan() throws {
        let f = try ManifestChangeTests.fixture()
        let plan = try planManifestChange(f.input(.demote(targets: [f.homeFile(".zshrc")])), hostname: "host")
        guard case let .demoteFile(_, _, entryTarget, entrySource) = plan.actions[0].kind else {
            Issue.record("expected demote_file")
            return
        }
        #expect(entryTarget == "~/.zshrc")
        #expect(entrySource == "zsh/zshrc")
        let replaced = ManifestChangeTests.manifestBody.replacingOccurrences(of: "zsh/zshrc", with: "zsh/other")
        try replaced.write(toFile: f.manifest.string, atomically: false, encoding: .utf8)

        let message = try #require(Self.stepFailure { try applyPlan(plan, context: f.context("d")) })
        #expect(message.contains("not the planned entry"), "\(message)")
        #expect(try f.manifestText() == replaced)
    }

    @Test func demoteRefusesEntryRewrittenWithAnotherTargetSpelling() throws {
        let f = try ManifestChangeTests.fixture()
        let plan = try planManifestChange(f.input(.demote(targets: [f.homeFile(".zshrc")])), hostname: "host")
        let respelled = ManifestChangeTests.manifestBody.replacingOccurrences(
            of: #"target = "~/.zshrc""#, with: "target = \"\(f.homeFile(".zshrc").string)\""
        )
        try respelled.write(toFile: f.manifest.string, atomically: false, encoding: .utf8)

        let message = try #require(Self.stepFailure { try applyPlan(plan, context: f.context("d")) })
        #expect(message.contains("not the planned entry"), "\(message)")
        #expect(try f.manifestText() == respelled)
    }

    @Test func demoteRefusesWhenASecondEntrySharesTheTarget() throws {
        let f = try ManifestChangeTests.fixture()
        let plan = try planManifestChange(f.input(.demote(targets: [f.homeFile(".zshrc")])), hostname: "host")
        // Same machine path spelled differently, so manifest validation accepts both entries.
        let doubled = ManifestChangeTests.manifestBody.replacingOccurrences(
            of: "# trailing section comment",
            with: "[[files]]\nsource = \"zsh/other\"\ntarget = \"\(f.homeFile(".zshrc").string)\"\n\n# trailing section comment"
        )
        try doubled.write(toFile: f.manifest.string, atomically: false, encoding: .utf8)
        #expect(try parseManifest(doubled).files.count == 2)

        let message = try #require(Self.stepFailure { try applyPlan(plan, context: f.context("d")) })
        #expect(message.contains("2 manifest entries"), "\(message)")
        #expect(try f.manifestText() == doubled)
    }

    // MARK: - A33-2c: promote never overwrites an edited repository source

    @Test func promoteRefusesRepoSourceCreatedAfterPlan() throws {
        let f = try ManifestChangeTests.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        guard case let .promoteFile(_, _, _, _, _, _, sourceSha256) = plan.actions[0].kind else {
            Issue.record("expected promote_file")
            return
        }
        #expect(sourceSha256 == nil)
        try "user file\n".write(toFile: f.repoPath.appending("gitconfig").string, atomically: false, encoding: .utf8)

        let message = try #require(Self.stepFailure { try applyPlan(plan, context: f.context("p")) })
        #expect(message.contains("plan expected it to be absent"), "\(message)")
        #expect(try text(f.repoPath.appending("gitconfig")) == "user file\n")
        #expect(try f.manifestText() == ManifestChangeTests.manifestBody)
    }

    @Test func promoteRefusesExistingRepoSourceEditedAfterPlan() throws {
        let f = try ManifestChangeTests.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        try "planned\n".write(toFile: f.repoPath.appending("gitconfig").string, atomically: false, encoding: .utf8)
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        guard case let .promoteFile(_, _, _, _, _, _, sourceSha256) = plan.actions[0].kind else {
            Issue.record("expected promote_file")
            return
        }
        #expect(sourceSha256 == sha256Hex(Array("planned\n".utf8)))
        try "edited\n".write(toFile: f.repoPath.appending("gitconfig").string, atomically: false, encoding: .utf8)

        let message = try #require(Self.stepFailure { try applyPlan(plan, context: f.context("p")) })
        #expect(message.contains("changed after the plan was approved"), "\(message)")
        #expect(try text(f.repoPath.appending("gitconfig")) == "edited\n")
        #expect(try f.manifestText() == ManifestChangeTests.manifestBody)
    }

    @Test func promoteRefusesRepoSourceRemovedAfterPlan() throws {
        let f = try ManifestChangeTests.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let source = f.repoPath.appending("gitconfig")
        try "planned\n".write(toFile: source.string, atomically: false, encoding: .utf8)
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        try FileManager.default.removeItem(atPath: source.string)

        let message = try #require(Self.stepFailure { try applyPlan(plan, context: f.context("p")) })
        #expect(message.contains("removed after the plan was approved"), "\(message)")
        #expect(!pathPresent(source))
        #expect(try f.manifestText() == ManifestChangeTests.manifestBody)
    }

    @Test func promoteReplacesUnchangedPlannedRepoSourceWithBackup() throws {
        let f = try ManifestChangeTests.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let source = f.repoPath.appending("gitconfig")
        try "planned\n".write(toFile: source.string, atomically: false, encoding: .utf8)
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")

        let journal = try applyPlan(plan, context: f.context("p"))
        #expect(journal.steps.map(\.status) == [.done])
        #expect(try text(source) == "[user]\n")
    }

    // MARK: - Re-check right before a replace

    @Test func requireUnchangedDetectsEditsBetweenReadAndWrite() throws {
        let f = try ManifestChangeTests.fixture()
        let path = f.repoPath.appending("gitconfig")
        try "read\n".write(toFile: path.string, atomically: false, encoding: .utf8)
        try requireUnchanged(path, expected: Array("read\n".utf8), what: "manifest")

        try "edited meanwhile\n".write(toFile: path.string, atomically: false, encoding: .utf8)
        #expect(throws: ApplyIOError.self) { try requireUnchanged(path, expected: Array("read\n".utf8), what: "manifest") }
        #expect(throws: ApplyIOError.self) { try requireUnchanged(path, expected: nil, what: "repository path") }

        try FileManager.default.removeItem(atPath: path.string)
        try requireUnchanged(path, expected: nil, what: "repository path")
        #expect(throws: ApplyIOError.self) { try requireUnchanged(path, expected: Array("read\n".utf8), what: "manifest") }
    }

    // MARK: - Encoding

    @Test func plansWithoutNewFieldsStillDecode() throws {
        let promote = #"{"kind":"promote_file","target":"/h/.gitconfig","source":"/r/gitconfig","manifest":"/r/dotfilesync.toml","entry_source":"gitconfig","entry_target":"~/.gitconfig","target_sha256":"abc"}"#
        let decoded = try JSONDecoder().decode(ActionKind.self, from: Data(promote.utf8))
        #expect(decoded == .promoteFile(
            target: FilePath("/h/.gitconfig"), source: FilePath("/r/gitconfig"), manifest: FilePath("/r/dotfilesync.toml"),
            entrySource: "gitconfig", entryTarget: "~/.gitconfig", targetSha256: "abc", sourceSha256: nil
        ))
        // Re-encoding a legacy action reproduces the same bytes, so stored plan digests hold.
        #expect(try jsonStringCompact(decoded) == promote)

        let withHash = ActionKind.promoteFile(
            target: FilePath("/h/.gitconfig"), source: FilePath("/r/gitconfig"), manifest: FilePath("/r/dotfilesync.toml"),
            entrySource: "gitconfig", entryTarget: "~/.gitconfig", targetSha256: "abc", sourceSha256: "def"
        )
        let json = try jsonStringCompact(withHash)
        #expect(json.hasSuffix(#""target_sha256":"abc","source_sha256":"def"}"#))
        #expect(try JSONDecoder().decode(ActionKind.self, from: Data(json.utf8)) == withHash)

        let demote = ActionKind.demoteFile(
            target: FilePath("/h/.zshrc"), manifest: FilePath("/r/dotfilesync.toml"), entryTarget: "~/.zshrc", entrySource: "zsh/zshrc"
        )
        let demoteJSON = try jsonStringCompact(demote)
        #expect(demoteJSON
            == #"{"kind":"demote_file","target":"/h/.zshrc","manifest":"/r/dotfilesync.toml","entry_target":"~/.zshrc","entry_source":"zsh/zshrc"}"#)
        #expect(try JSONDecoder().decode(ActionKind.self, from: Data(demoteJSON.utf8)) == demote)
    }
}
