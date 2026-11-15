// Port of crates/dotfilesync-daemon/tests/state_tests.rs (in-process parts) and the inline
// tests in crates/dotfilesync-daemon/src/redact.rs.

import Agent
import Core
import Darwin
import Foundation
import IPC
import System
import Testing

private func allFiles(_ dir: FilePath) -> [FilePath] {
    guard let names = try? FileManager.default.subpathsOfDirectory(atPath: dir.string) else { return [] }
    return names.map { dir.appending($0) }.filter {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: $0.string, isDirectory: &isDir) && !isDir.boolValue
    }
}

@Suite(.serialized) struct StateTests {
    @Test func interruptedJobsAreReportedAndNeverReplayed() throws {
        let env = try Env(.fast)
        try env.layout.ensurePrivateDirs()
        do {
            let (j, _) = try JobJournal.openAndRecover(env.layout.journal)
            try j.append(jobId: "j-done", kind: .scan, event: .started)
            try j.append(jobId: "j-done", kind: .scan, event: .succeeded)
            try j.append(jobId: "j-crashed", kind: .status, event: .started)
        }
        // Plus a corrupt line, which must be skipped rather than abort startup.
        let fh = try #require(FileHandle(forWritingAtPath: env.layout.journal.string))
        fh.seekToEndOfFile()
        fh.write(Data("{not json\n".utf8))
        try fh.close()

        let d = try env.start()
        let jobs = try d.listJobs()
        let crashed = try #require(jobs.first { $0.jobId == "j-crashed" })
        #expect(crashed.status == .interrupted)
        #expect(crashed.fromPreviousRun)
        #expect(crashed.error?.message.contains("not resumed or replayed") == true)
        let done = try #require(jobs.first { $0.jobId == "j-done" })
        #expect(done.status == .succeeded)
        #expect(errorCode { try d.jobResult("j-crashed") }?.code == .jobFailed)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(env.brewRuns() == 0, "recovery must not re-run work")
        d.shutdown()

        let journal = readText(env.layout.journal)
        #expect(journal.contains("\"interrupted\""))
        #expect(!journal.contains("{not json"), "compaction drops corrupt lines")
        let log = readText(env.layout.logFile)
        #expect(log.contains("skipped 1 corrupt line"))
        #expect(log.contains("1 job(s) from the previous run were interrupted"))
    }

    @Test func journalIsCompactedToABound() throws {
        let env = try Env(.fast)
        try env.layout.ensurePrivateDirs()
        do {
            let (j, _) = try JobJournal.openAndRecover(env.layout.journal)
            for i in 0..<500 {
                try j.append(jobId: "j-\(i)", kind: .scan, event: .started)
                try j.append(jobId: "j-\(i)", kind: .scan, event: .succeeded)
            }
        }
        let (_, report) = try JobJournal.openAndRecover(env.layout.journal)
        #expect(report.jobs.count == JOURNAL_RETAIN)
        #expect(report.jobs.last?.jobId == "j-499")
        let lines = readText(env.layout.journal).split(separator: "\n").count
        #expect(lines == 2 * JOURNAL_RETAIN)
    }

    @Test func journalRecordsMatchRustFormat() throws {
        let env = try Env(.fast)
        try env.layout.ensurePrivateDirs()
        let (j, _) = try JobJournal.openAndRecover(env.layout.journal)
        try j.append(jobId: "j-1", kind: .plan, event: .started)
        let line = readText(env.layout.journal)
        #expect(line.hasPrefix(#"{"job_id":"j-1","kind":"plan","event":"started","at_ms":"#))
        #expect(line.hasSuffix("}\n"))
        #expect(modeOf(env.layout.journal) == 0o600)
        // Unknown fields are corrupt (serde deny_unknown_fields).
        try (line + #"{"job_id":"x","kind":"scan","event":"started","at_ms":1,"extra":1}"# + "\n")
            .write(toFile: env.layout.journal.string, atomically: false, encoding: .utf8)
        let (_, report) = try JobJournal.openAndRecover(env.layout.journal)
        #expect(report.corruptLines == 1)
    }

    @Test func logLinesAreRedactedAndLogsRotateWithinBounds() throws {
        let tmp = try Env(.fast)
        let dir = tmp.tmp.appending("logs")
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let path = dir.appending("d.log")
        let log = try Logger(path: path, maxBytes: 2048, keep: 2)
        log.info("push with token ghp_abcdefghijklmnopqrstuvwxyz0123 to https://me:hunter2@github.com/x")
        log.warn("password=hunter2 Authorization: Bearer sekrit-value")
        let text = readText(path)
        for secret in ["ghp_abcdef", "hunter2", "sekrit-value"] {
            #expect(!text.contains(secret), "\(secret) leaked: \(text)")
        }
        #expect(text.contains("[REDACTED]"))
        log.info("line one\nFAKE ERROR injected")
        #expect(!readText(path).split(separator: "\n").contains { $0.hasPrefix("FAKE") })

        for i in 0..<500 {
            log.info("filler line \(i) \(String(repeating: "x", count: 40))")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.string)
        #expect(files.count <= 3, "current + 2 rotated files, got \(files.count)")
        for f in files {
            let p = dir.appending(f)
            let size = (try FileManager.default.attributesOfItem(atPath: p.string)[.size] as? Int) ?? 0
            #expect(size <= 2048, "\(f) is \(size) bytes")
            #expect(modeOf(p) == 0o600)
        }
    }

    @Test func stateAndLogsOmitConfigBodiesPathsAndSecrets() throws {
        let env = try Env(.fast)
        let repo = env.tmp.appending("repo")
        try FileManager.default.createDirectory(atPath: repo.appending("cfg").string, withIntermediateDirectories: true)
        let secretBody = "API_TOKEN=ghp_SENTINELSECRET0000000000000000 BODY_SENTINEL_42"
        try secretBody.write(toFile: repo.appending("cfg/app.conf").string, atomically: false, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: env.home.appending(".config").string, withIntermediateDirectories: true)
        try secretBody.write(toFile: env.home.appending(".config/app.conf").string, atomically: false, encoding: .utf8)
        let manifest = repo.appending("dotfilesync.toml")
        try "schema_version = 1\n\n[[files]]\nsource = \"cfg/app.conf\"\ntarget = \"~/.config/app.conf\"\n"
            .write(toFile: manifest.string, atomically: false, encoding: .utf8)

        let d = try env.start()
        let job = try d.startJob(.scan(ScanInput(manifest: manifest, home: env.home)))
        _ = try d.watchJob(job.jobId, 0)
        guard case let .scan(report) = try d.jobResult(job.jobId) else {
            Issue.record("expected scan")
            return
        }
        #expect(report.configs.count == 1)
        d.shutdown()

        for f in allFiles(env.layout.root) {
            let text = readText(f)
            for needle in ["SENTINELSECRET", "BODY_SENTINEL_42", "app.conf", manifest.string, env.home.string] {
                #expect(!text.contains(needle), "\(f) contains \(needle)")
            }
        }
    }

    @Test func approvalTokensNeverReachStateOrLogs() throws {
        let env = try Env(.fast)
        let (_, input) = try applyFixture(env)
        let d = try env.start()
        let started = try d.planCreate(input)
        _ = try d.waitTerminal(started.jobId)
        guard case let .plan(plan, planId) = try d.jobResult(started.jobId) else {
            Issue.record("expected plan")
            return
        }
        let grant = try d.planApprove(planId, plan.digest)
        let job = try d.planApply(planId, grant.token, false)
        _ = try d.waitTerminal(job.jobId)
        d.shutdown()
        for f in allFiles(env.layout.root) {
            #expect(!readText(f).contains(grant.token), "\(f) contains the approval token")
        }
    }
}

// MARK: - redact.rs inline tests

@Suite struct RedactTests {
    @Test func redactsGithubTokens() {
        #expect(redact("pushing with ghp_abcdefghijklmnopqrstuvwxyz0123456789 now") == "pushing with [REDACTED] now")
        let s = redact("x=github_pat_11ABCDEFG_hijklmnop")
        #expect(!s.contains("11ABCDEFG"), "\(s)")
    }

    @Test func redactsAuthHeadersAndKeyValues() {
        #expect(redact("Authorization: Bearer abc.def.ghi") == "Authorization: Bearer [REDACTED]")
        #expect(redact("Basic dXNlcjpwYXNz") == "Basic [REDACTED]")
        #expect(redact("password=hunter2") == "password=[REDACTED]")
        #expect(redact("API_KEY: sk-12345") == "API_KEY: [REDACTED]")
        #expect(redact("db_secret=\"xyz\"") == "db_secret=[REDACTED]")
        #expect(redact("approval token issued") == "approval token issued")
    }

    @Test func redactsUrlUserinfo() {
        #expect(redact("cloning https://user:pa55@github.com/me/repo.git") == "cloning https://[REDACTED]@github.com/me/repo.git")
    }

    @Test func leavesOrdinaryTextAlone() {
        let s = "job j-0123 kind=scan status=succeeded path=/Users/me/.config"
        #expect(redact(s) == s)
        #expect(redact("url=https://example.com/x") == "url=https://example.com/x")
    }
}
