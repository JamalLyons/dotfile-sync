@testable import Agent
import Core
import Foundation
import IPC
import System
import Testing

private struct ConfigFixture {
    let env: Env
    let input: PlanInput
    let target: FilePath
    let source: FilePath

    init(managed: Bool = false) throws {
        env = try Env(.fast)
        let repo = env.tmp.appending("repo")
        input = PlanInput(manifest: repo.appending("dotfilesync.toml"), home: env.home)
        target = env.home.appending(".config/fish/config.fish")
        source = repo.appending("fish/config.fish")
        try FileManager.default.createDirectory(atPath: target.removingLastComponent().string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: source.removingLastComponent().string, withIntermediateDirectories: true)
        try "local\n".write(toFile: target.string, atomically: true, encoding: .utf8)
        var manifest = "schema_version = 1\n"
        if managed {
            try "repo\n".write(toFile: source.string, atomically: true, encoding: .utf8)
            manifest += """

            [[files]]
            source = "fish/config.fish"
            target = "~/.config/fish/config.fish"

            """
        }
        try manifest.write(toFile: input.manifest.string, atomically: true, encoding: .utf8)
    }
}

@Suite struct ConfigOperationTests {
    @Test func discoversFishInOwnerHome() throws {
        let fixture = try ConfigFixture()
        let agent = try fixture.env.start()
        defer { agent.shutdown() }
        guard case let .configDiscovery(report) = try agent.call(.configDiscover()) else {
            Issue.record("expected a discovery report")
            return
        }
        let fish = try #require(report.tools.first { $0.id == "fish" })
        #expect(fish.configRoots == [fixture.target.removingLastComponent()])
        #expect(report.entries.contains { $0.path == fixture.target && $0.language == .fish })
    }

    @Test func treeAndDiffReportManagedModification() throws {
        let fixture = try ConfigFixture(managed: true)
        let agent = try fixture.env.start()
        defer { agent.shutdown() }
        let manifest = fixture.input.manifest
        guard case let .configTree(tree) = try agent.call(.configTree(manifest: manifest)),
              case let .configDiff(diff) = try agent.call(.configDiff(target: ".config/fish/config.fish", manifest: manifest))
        else {
            Issue.record("expected a tree and a diff")
            return
        }
        #expect(tree.root.aggregate?.modified == 1)
        #expect(diff.status == .changed)
        #expect(diff.managedSource == "fish/config.fish")
        #expect(diff.hunks.flatMap(\.lines) == ["-repo", "+local"])
    }

    @Test func openSaveConflictPreservesFileAndReportsBackupsOnSuccess() throws {
        let fixture = try ConfigFixture()
        let agent = try fixture.env.start()
        defer { agent.shutdown() }
        let path = fixture.target.string
        guard case let .configDocument(document) = try agent.call(.configOpen(path: path)) else {
            Issue.record("expected a config document")
            return
        }
        #expect(document.text == "local\n")
        #expect(!document.isBinary)
        try "external\n".write(toFile: path, atomically: true, encoding: .utf8)
        let conflict = errorCode {
            try agent.call(.configSave(path: path, text: "edited\n", expectedVersion: document.version))
        }
        #expect(conflict?.code == .conflict)
        #expect(conflict?.details != nil)
        #expect(readText(fixture.target) == "external\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.env.layout.editorBackupsDir.string))

        guard case let .configWrite(report) = try agent.call(.configSave(
            path: path, text: "edited\n", expectedVersion: document.version, force: true
        )) else {
            Issue.record("expected a write report")
            return
        }
        let backupPath = FilePath(try #require(report.backupPath))
        #expect(backupPath.starts(with: try canonicalize(fixture.env.layout.editorBackupsDir)))
        #expect(readText(backupPath) == "external\n")
        #expect(readText(fixture.target) == "edited\n")
        #expect(readText(fixture.env.layout.logFile).contains("path=\(path) backup_path=\(backupPath.string)"))
    }

    @Test func editorRejectsFilesOutsideDiscoveredRoots() throws {
        let fixture = try ConfigFixture()
        let agent = try fixture.env.start()
        defer { agent.shutdown() }
        let unregistered = fixture.env.home.appending(".unregistered")
        try "keep\n".write(toFile: unregistered.string, atomically: true, encoding: .utf8)
        let version = FileVersion(mtimeNs: 0, size: 0, sha256: "")
        let forced = Request.configSave(path: unregistered.string, text: "clobber", expectedVersion: version, force: true)
        #expect(errorCode { try agent.call(forced) }?.code == .invalidParams)
        #expect(readText(unregistered) == "keep\n")

        let outside = fixture.env.tmp.appending("elsewhere")
        let directory = outside.appending(".config/fish")
        try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
        let outsideFile = directory.appending("config.fish")
        try "outside\n".write(toFile: outsideFile.string, atomically: true, encoding: .utf8)
        // config.* is pinned to the owner's HOME so classification cannot be re-anchored.
        #expect(errorCode { try agent.call(.configDiscover(home: outside)) }?.code == .invalidParams)
        var otherHome = fixture.input
        otherHome.home = outside
        #expect(errorCode { try agent.call(.configTree(manifest: otherHome.manifest, home: outside, repoRoot: nil, profile: nil)) }?.code == .invalidParams)
        #expect(errorCode { try agent.call(.configPromote(input: otherHome, targets: [outsideFile])) }?.code == .invalidParams)
        #expect(errorCode { try agent.call(.configOpen(path: outsideFile.string)) }?.code == .invalidParams)
        #expect(errorCode { try agent.call(.configOpen(path: fixture.target.string + "\0suffix")) }?.code == .invalidParams)
        let symlink = fixture.env.home.appending(".config/nvim")
        try FileManager.default.createSymbolicLink(atPath: symlink.string, withDestinationPath: directory.string)
        #expect(errorCode { try agent.call(.configOpen(path: symlink.appending("config.fish").string)) }?.code == .invalidParams)
    }

    @Test func editorRefusesSecretLikeAndExcludedFilesInsideRootsWithoutReading() throws {
        let fixture = try ConfigFixture()
        let agent = try fixture.env.start()
        defer { agent.shutdown() }
        let fish = fixture.target.removingLastComponent()
        let secret = fish.appending("secrets.fish")
        let history = fish.appending("fish_history")
        for file in [secret, history] {
            try "keep\n".write(toFile: file.string, atomically: true, encoding: .utf8)
            // Unreadable: an open attempt would surface EACCES rather than the classification refusal.
            chmod(file.string, 0o000)
            defer { chmod(file.string, 0o600) }
            let open = errorCode { try agent.call(.configOpen(path: file.string)) }
            #expect(open?.code == .invalidParams)
            #expect(open?.message.contains("excluded from editing") == true)
            let version = FileVersion(mtimeNs: 0, size: 0, sha256: "")
            let save = Request.configSave(path: file.string, text: "clobber", expectedVersion: version, force: true)
            #expect(errorCode { try agent.call(save) }?.code == .invalidParams)
        }
        #expect(readText(secret) == "keep\n")
        let create = Request.configCreate(path: fish.appending("api_token.fish").string, text: "x")
        #expect(errorCode { try agent.call(create) }?.code == .invalidParams)
        let rename = Request.configRename(from: fixture.target.string, to: fish.appending("my_secret.fish").string)
        #expect(errorCode { try agent.call(rename) }?.code == .invalidParams)
        #expect(readText(fixture.target) == "local\n")

        // A canonical or otherwise non-HOME spelling of the same file must not skip classification.
        let canonicalHome = try canonicalize(fixture.env.home)
        if canonicalHome != fixture.env.home {
            let alias = canonicalHome.appending(".config/fish/secrets.fish")
            #expect(errorCode { try agent.call(.configOpen(path: alias.string)) }?.code == .invalidParams)
        }
        #expect(errorCode { try agent.call(.configOpen(path: "relative/config.fish")) }?.code == .invalidParams)
    }

    @Test func editorCreatesAndRenamesWithoutReplacingExistingContents() throws {
        let fixture = try ConfigFixture()
        let agent = try fixture.env.start()
        defer { agent.shutdown() }
        let dir = fixture.target.removingLastComponent()
        let created = dir.appending("new.fish")
        let renamed = dir.appending("moved.fish")
        guard case let .configWrite(create) = try agent.call(.configCreate(path: created.string, text: "new\n")),
              case let .configWrite(rename) = try agent.call(.configRename(from: created.string, to: renamed.string))
        else {
            Issue.record("expected write reports")
            return
        }
        #expect(create.path == created.string)
        #expect(rename.path == renamed.string)
        #expect(create.backupPath == nil)
        #expect(rename.backupPath == nil)
        #expect(readText(renamed) == "new\n")
        #expect(errorCode { try agent.call(.configOpen(path: created.string)) }?.code == .notFound)
        #expect(errorCode { try agent.call(.configRename(from: renamed.string, to: fixture.target.string)) }?.code == .conflict)
        #expect(readText(fixture.target) == "local\n")
    }

    @Test func promoteAndDemoteUseApprovedPlanJobs() throws {
        let fixture = try ConfigFixture()
        let agent = try fixture.env.start()
        defer { agent.shutdown() }
        let promotion = try makePlan(agent, .configPromote(input: fixture.input, targets: [fixture.target]))
        #expect(promotion.actions.map(\.kind.tag) == ["promote_file"])
        #expect(try loadManifest(fixture.input.manifest.string).files.isEmpty)
        _ = try apply(agent, promotion)
        let promoted = try loadManifest(fixture.input.manifest.string)
        #expect(promoted.files.map(\.target) == ["~/.config/fish/config.fish"])
        #expect(readText(fixture.source) == "local\n")

        let demotion = try makePlan(agent, .configDemote(input: fixture.input, targets: [fixture.target]))
        #expect(demotion.actions.map(\.kind.tag) == ["demote_file"])
        _ = try apply(agent, demotion)
        #expect(try loadManifest(fixture.input.manifest.string).files.isEmpty)
        #expect(readText(fixture.target) == "local\n")
        #expect(readText(fixture.source) == "local\n")
    }

    @Test(arguments: [false, true])
    func promotionFailsClosedWhenTargetChanges(remove: Bool) throws {
        let fixture = try ConfigFixture()
        let agent = try fixture.env.start()
        defer { agent.shutdown() }
        let promotion = try makePlan(agent, .configPromote(input: fixture.input, targets: [fixture.target]))
        let grant = try agent.planApprove(promotion.planId, promotion.digest)
        if remove {
            try FileManager.default.removeItem(atPath: fixture.target.string)
        } else {
            try "changed\n".write(toFile: fixture.target.string, atomically: true, encoding: .utf8)
        }
        let refused = errorCode { try agent.planApply(promotion.planId, grant.token, false) }
        #expect(refused?.code == .approvalRejected)
        #expect(refused?.reason == "state_changed")
        #expect(errorCode { try agent.planApply(promotion.planId, grant.token, false) }?.reason == "already_used")
        #expect(errorCode { try agent.planApprove(promotion.planId, promotion.digest) }?.reason == "state_changed")
        #expect(try loadManifest(fixture.input.manifest.string).files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.source.string))
    }

    @Test func queuedPromotionRechecksStateAfterEditorWrite() throws {
        let fixture = try ConfigFixture()
        let config = fixture.env.config()
        try config.layout.ensurePrivateDirs()
        let (journal, recovered) = try JobJournal.openAndRecover(config.layout.journal)
        let locks = ResourceLocks()
        let log = Logger.disabled()
        let jobs = JobManager(
            journal: journal, log: log, locks: locks, brewBin: config.brewBin, limits: config.jobs,
            recovered: recovered.jobs, paths: JobPaths(
                runsDir: config.layout.runsDir, backupsDir: config.layout.backupsDir, ownerUid: config.ownerUid, home: config.home
            ), presence: config.presence
        )
        defer { _ = jobs.shutdown(grace: .seconds(1)) }
        let job = try jobs.startManifestChange(fixture.input, change: .promote(targets: [fixture.target]), ownerUid: config.ownerUid)
        try #require(waitUntil(.seconds(5)) { (try? jobs.get(job.jobId).status.isTerminal) == true })
        guard case let .plan(plan, id) = try jobs.result(job.jobId) else {
            throw TestFailure(description: "expected a plan")
        }
        let grant = try jobs.approve(planId: id, digest: plan.digest, approverUid: config.ownerUid)
        let editor = ConfigOperations(config: config, locks: locks, log: log)
        let document = try editor.open(path: fixture.target.string)

        // Apply can redeem the token, but its worker must wait for the apply locks.
        let hold = try locks.acquire([(.homebrew, .shared)])
        defer { hold.release() }
        let applying = try jobs.apply(planId: id, token: grant.token, allowSudo: false, callerUid: config.ownerUid)
        _ = try editor.edit(paths: [fixture.target.string], { editor throws(EditorError) in
            try editor.save(path: fixture.target.string, text: "edited\n", expectedVersion: document.version)
        }, shuttingDown: { false })
        hold.release()

        try #require(waitUntil(.seconds(5)) { (try? jobs.get(applying.jobId).status.isTerminal) == true })
        let finished = try jobs.get(applying.jobId).snapshot()
        #expect(finished.status == .failed)
        #expect(finished.error?.message.contains("state changed") == true)
        #expect(try loadManifest(fixture.input.manifest.string).files.isEmpty)
    }

    @Test func manifestChangeResumesAfterRestartWithPartiallyChangedState() throws {
        let fixture = try ConfigFixture()
        let agent = try fixture.env.start()
        defer { agent.shutdown() }
        let promotion = try makePlan(agent, .configPromote(input: fixture.input, targets: [fixture.target]))
        let journal = try apply(agent, promotion)
        agent.shutdown()
        #expect(try manifestChangeFingerprint(promotion) != promotion.stateFingerprint)

        // Simulate an interruption after the file and manifest were written but before the
        // terminal step and status were persisted.
        let runDir = fixture.env.layout.runsDir.appending(journal.runId)
        let steps = runDir.appending("journal.jsonl")
        let records = readText(steps).split(separator: "\n")
        try #require(records.last?.contains("\"status\":\"done\"") == true)
        try (records.dropLast().joined(separator: "\n") + "\n")
            .write(toFile: steps.string, atomically: false, encoding: .utf8)
        let metadata = runDir.appending("meta.json")
        try readText(metadata).replacingOccurrences(of: "\"status\":\"succeeded\"", with: "\"status\":\"running\"")
            .write(toFile: metadata.string, atomically: false, encoding: .utf8)

        let restarted = try fixture.env.start()
        defer { restarted.shutdown() }
        let run = try restarted.planRunStatus(journal.runId)
        #expect(run.status == .interrupted)
        let approval = try restarted.planApprove(run.planId, run.planDigest)
        let resume = try restarted.planResume(run.runId, approval.token, false)
        #expect(try restarted.waitTerminal(resume.jobId).status == .succeeded)
        #expect(try loadManifest(fixture.input.manifest.string).files.map(\.target) == ["~/.config/fish/config.fish"])
    }

    private func makePlan(_ agent: AgentService, _ request: Request) throws -> Plan {
        guard case let .job(job) = try agent.call(request) else { throw TestFailure(description: "expected a plan job") }
        #expect(job.kind == .plan)
        #expect(try agent.waitTerminal(job.jobId).status == .succeeded)
        guard case let .plan(plan, id) = try agent.jobResult(job.jobId) else { throw TestFailure(description: "expected a plan") }
        #expect(plan.planId == id)
        return plan
    }

    private func apply(_ agent: AgentService, _ plan: Plan) throws -> RunJournal {
        let approval = try agent.planApprove(plan.planId, plan.digest)
        let job = try agent.planApply(plan.planId, approval.token, false)
        #expect(try agent.waitTerminal(job.jobId).status == .succeeded)
        guard case let .apply(journal) = try agent.jobResult(job.jobId) else { throw TestFailure(description: "expected an apply journal") }
        return journal
    }
}
