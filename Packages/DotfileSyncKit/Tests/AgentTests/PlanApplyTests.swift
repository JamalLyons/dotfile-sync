// Port of crates/dotfilesync-daemon/tests/plan_apply_tests.rs.

import Agent
import Core
import Darwin
import Foundation
import IPC
import System
import Testing

func writeApplyBrew(_ path: FilePath) throws {
    try writeScript(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
        echo "Homebrew 4.3.0"
        exit 0
    fi
    if [ "$1" = "info" ]; then
        echo '\(BREW_JSON)'
        exit 0
    fi
    if [ "$1" = "install" ]; then
        sleep 1
        exit 0
    fi
    if [ "$1" = "list" ]; then
        exit 0
    fi
    exit 1

    """)
}

/// The Rust `fixture`: a manifest with one formula and one backed-up config copy.
func applyFixture(_ env: Env) throws -> (target: FilePath, input: PlanInput) {
    try writeApplyBrew(env.brew)
    let repo = env.tmp.appending("repo")
    try FileManager.default.createDirectory(atPath: repo.string, withIntermediateDirectories: true)
    try "desired\n".write(toFile: repo.appending("config.txt").string, atomically: false, encoding: .utf8)
    let manifest = repo.appending("dotfilesync.toml")
    try """
    schema_version = 1

    [package_managers.homebrew]
    formulae = ["ripgrep"]

    [[files]]
    source = "config.txt"
    target = "~/.config/demo/config.txt"

    """.write(toFile: manifest.string, atomically: false, encoding: .utf8)
    let targetDir = env.home.appending(".config/demo")
    try FileManager.default.createDirectory(atPath: targetDir.string, withIntermediateDirectories: true)
    try "old\n".write(toFile: targetDir.appending("config.txt").string, atomically: false, encoding: .utf8)
    return (targetDir.appending("config.txt"), PlanInput(manifest: manifest, home: env.home, repoRoot: repo))
}

private func countFiles(_ dir: FilePath) -> Int {
    guard let e = FileManager.default.enumerator(atPath: dir.string) else { return 0 }
    var n = 0
    while let p = e.nextObject() as? String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.appending(p).string, isDirectory: &isDir), !isDir.boolValue {
            n += 1
        }
    }
    return n
}

@Suite(.serialized) struct PlanApplyTests {
    @Test func applySurvivesCallerGoingAwayAndRejectsReplayAndTamperedDigest() throws {
        let env = try Env(.fast)
        let (target, input) = try applyFixture(env)
        let d = try env.start()
        defer { d.shutdown() }

        let started = try d.planCreate(input)
        let planned = try d.waitTerminal(started.jobId)
        #expect(planned.status == .succeeded, "\(planned)")
        guard case let .plan(plan, planId) = try d.jobResult(started.jobId) else {
            Issue.record("plan job did not return a plan")
            return
        }
        #expect(planId == plan.planId)
        #expect(plan.actions.contains { if case .brewInstallFormula = $0.kind { return true }; return false })
        #expect(plan.actions.contains { if case .copyFile = $0.kind { return $0.backup }; return false })

        let tampered = errorCode { try d.planApprove(planId, "tampered-digest") }
        #expect(tampered?.code == .approvalRejected)
        #expect(tampered?.reason == "plan_mismatch")

        let grant = try d.planApprove(planId, plan.digest)
        let jobId = try d.planApply(planId, grant.token, false).jobId
        let token = grant.token

        // The applying caller is gone; a later caller observes the same job.
        let mid = try d.jobStatus(jobId)
        #expect([.queued, .running, .succeeded].contains(mid.status), "\(mid)")
        let finished = try d.waitTerminal(jobId)
        #expect(finished.status == .succeeded, "\(finished)")
        guard case let .apply(journal) = try d.jobResult(jobId) else {
            Issue.record("apply job did not return a journal")
            return
        }
        let view = try d.planRunStatus(journal.runId)
        #expect(view.status == .succeeded)
        #expect(view.runId == journal.runId)
        #expect(view.steps.contains { $0.status == .done }, "\(view)")
        #expect(readText(target) == "desired\n")
        #expect(countFiles(env.layout.backupsDir) > 0, "backup of the previous target must exist")
        #expect(modeOf(env.layout.runsDir) == 0o700)
        #expect(modeOf(env.layout.backupsDir) == 0o700)
        // On-disk run layout: runs/<run_id>/{journal.jsonl,plan.json,meta.json}, meta 0600.
        let runDir = env.layout.runsDir.appending(journal.runId)
        for name in ["journal.jsonl", "plan.json", "meta.json"] {
            #expect(FileManager.default.fileExists(atPath: runDir.appending(name).string), "\(name)")
        }
        #expect(modeOf(runDir.appending("meta.json")) == 0o600)
        #expect(readText(runDir.appending("meta.json")).hasPrefix("{\"run_id\":\"\(journal.runId)\",\"plan_id\":\"\(planId)\""))

        let replay = errorCode { try d.planApply(planId, token, false) }
        #expect(replay?.code == .approvalRejected)
        #expect(replay?.reason == "already_used")
    }

    @Test func unfinishedRunIsInterruptedAfterRestartAndCanResume() throws {
        let env = try Env(.fast)
        try env.start().shutdown()

        let repo = env.tmp.appending("repo")
        try FileManager.default.createDirectory(atPath: repo.appending("unused").string, withIntermediateDirectories: true)
        try "desired\n".write(toFile: repo.appending("config.txt").string, atomically: false, encoding: .utf8)
        let manifest = repo.appending("dotfilesync.toml")
        try "schema_version = 1\n\n[[files]]\nsource = \"config.txt\"\ntarget = \"~/.config/demo/config.txt\"\n"
            .write(toFile: manifest.string, atomically: false, encoding: .utf8)
        let target = env.home.appending(".config/demo/config.txt")
        try FileManager.default.createDirectory(atPath: env.home.appending(".config/demo").string, withIntermediateDirectories: true)
        try "old\n".write(toFile: target.string, atomically: false, encoding: .utf8)

        let plan = Plan(
            schema: PLAN_SCHEMA,
            profile: nil,
            manifestPath: manifest,
            home: env.home,
            repoRoot: repo,
            actions: [PlanAction(
                id: "a-001",
                kind: .copyFile(source: repo.appending("config.txt"), target: target),
                summary: "copy config",
                risk: .medium,
                reversible: true,
                backup: true
            )],
            stateFingerprint: "fingerprint-for-resume"
        )
        let runId = "r-interrupted0001"
        let runDir = env.layout.runsDir.appending(runId)
        try FileManager.default.createDirectory(atPath: runDir.string, withIntermediateDirectories: true)
        chmod(runDir.string, 0o700)
        try jsonStringCompact(plan).write(toFile: runDir.appending("plan.json").string, atomically: false, encoding: .utf8)
        let header = #"{"event":"header","run_id":"\#(runId)","plan_digest":"\#(plan.digest)"}"#
        let step = #"{"event":"step","action_id":"a-001","status":"running","at_ms":1}"#
        try "\(header)\n\(step)\n".write(toFile: runDir.appending("journal.jsonl").string, atomically: false, encoding: .utf8)
        let meta = #"{"run_id":"\#(runId)","plan_id":"\#(plan.planId)","plan_digest":"\#(plan.digest)","job_id":"j-old0001","status":"running"}"#
        let metaPath = runDir.appending("meta.json")
        try meta.write(toFile: metaPath.string, atomically: false, encoding: .utf8)
        chmod(metaPath.string, 0o600)

        let d = try env.start()
        defer { d.shutdown() }
        let found = try #require(try d.planRuns().first { $0.runId == runId }, "run listed")
        #expect(found.status == .interrupted)
        let view = try d.planRunStatus(runId)
        #expect(view.status == .interrupted)

        let grant = try d.planApprove(view.planId, view.planDigest)
        let job = try d.planResume(runId, grant.token, false)
        let finished = try d.waitTerminal(job.jobId)
        #expect(finished.status == .succeeded, "\(finished)")
        #expect(readText(target) == "desired\n")
    }
}
