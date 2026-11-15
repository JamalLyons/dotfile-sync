// Port of crates/dotfilesync-daemon/tests/job_tests.rs, driving AgentService in-process.
// Serialized: several tests read the fake brew's pid file and rely on timing.

import Agent
import Core
import Darwin
import Foundation
import IPC
import System
import Testing

func scanSpec(_ env: Env) -> JobSpec {
    .scan(ScanInput(manifest: nil, home: env.home, repoRoot: nil, profile: nil))
}

@Suite(.serialized) struct JobTests {
    @Test func scanJobMatchesStandaloneCoreOutput() throws {
        let env = try Env(.fast)
        let d = try env.start()
        defer { d.shutdown() }
        let job = try d.startJob(scanSpec(env))
        #expect(job.kind == .scan)
        let done = try d.watchJob(job.jobId, 0)
        #expect(done.status == .succeeded)
        guard case let .scan(report) = try d.jobResult(job.jobId) else {
            Issue.record("wrong kind")
            return
        }
        let runner = RealCommandRunner().withBrewBinary(env.brew)
        let standalone = try runScan(ScanInput(manifest: nil, home: env.home), runner: runner)
        #expect(report == standalone, "agent and standalone share one implementation")
        #expect(report.homebrew.formulae.contains { $0.name == "git" })
    }

    @Test func statusJobWithFixtureManifestAndManifestFailure() throws {
        let env = try Env(.fast)
        let d = try env.start()
        defer { d.shutdown() }
        let manifest = repoRoot.appending("fixtures/sample_manifest.toml")
        let job = try d.startJob(.status(StatusInput(manifest: manifest, home: env.home)))
        _ = try d.watchJob(job.jobId, 0)
        guard case .status = try d.jobResult(job.jobId) else {
            Issue.record("expected status output")
            return
        }

        let bad = try d.startJob(.status(StatusInput(manifest: env.tmp.appending("missing.toml"), home: env.home)))
        let done = try d.watchJob(bad.jobId, 0)
        #expect(done.status == .failed)
        #expect(done.error?.code == .manifestLoad)
        #expect(errorCode { try d.jobResult(bad.jobId) }?.code == .jobFailed)
    }

    @Test func progressEventsAreOrderedAndStreamed() throws {
        let env = try Env(.slow(0.3))
        let d = try env.start()
        defer { d.shutdown() }
        let job = try d.startJob(scanSpec(env))
        var seen: [ProgressEvent] = []
        let done = try d.watchJob(job.jobId, 0) { seen.append($0) }
        #expect(done.status == .succeeded)
        #expect(seen.map(\.stage) == ["acquiring_locks", "discovering_homebrew", "done"])
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.seq < $1.seq })
        #expect(done.latestSeq == seen.last?.seq)
    }

    @Test func jobSurvivesCallerGoingAwayAndLaterCallerSeesProgressAndResult() throws {
        let env = try Env(.slow(1.0))
        let d = try env.start()
        defer { d.shutdown() }
        // The "client" that started the job goes away: it is just a value that is dropped.
        let id: String = try {
            let job = try d.startJob(scanSpec(env))
            return job.jobId
        }()
        let j = try d.jobStatus(id)
        #expect(!j.status.isTerminal, "job must not be cancelled by disconnect")
        #expect(!j.cancelRequested)

        // In-process calls have no socket round trip, so give the worker thread a moment to
        // push its first event (Rust gets this from the reconnect latency).
        #expect(waitUntil(.seconds(2)) { ((try? d.jobStatus(id))?.latestSeq ?? 0) >= 1 })
        let (_, missed, truncated) = try d.jobProgress(id, 0)
        #expect(!truncated)
        #expect(missed.contains { $0.stage == "acquiring_locks" })
        let last = try #require(missed.last).seq
        var later: [UInt64] = []
        let done = try d.watchJob(id, last) { later.append($0.seq) }
        #expect(done.status == .succeeded)
        #expect(later.allSatisfy { $0 > last }, "no duplicate events after reconnect")
        guard case .scan = try d.jobResult(id) else {
            Issue.record("expected scan output")
            return
        }
    }

    @Test func watcherDisconnectMidStreamDoesNotCancel() throws {
        let env = try Env(.slow(0.8))
        let d = try env.start()
        defer { d.shutdown() }
        let id = try d.startJob(scanSpec(env)).jobId
        // A watcher receives one notification, then its transport goes away (send fails).
        var received = 0
        let outcome = d.watch(jobId: id, sinceSeq: 0) { (_: IPC.Notification) in
            received += 1
            return false
        }
        #expect(outcome == nil)
        #expect(received == 1)
        let j = try d.waitStatus(id, .succeeded)
        #expect(!j.cancelRequested)
        #expect(try d.call(.ping) == .pong)
    }

    @Test func cancellationStopsJobAndKillsItsSubprocess() throws {
        let env = try Env(.hang)
        let d = try env.start()
        defer { d.shutdown() }
        let job = try d.startJob(scanSpec(env))
        let brewPid = try env.waitForBrewPid()
        let guardPid = PidGuard(brewPid)
        defer { withExtendedLifetime(guardPid) {} }
        #expect(processAlive(brewPid))

        let snap = try d.cancelJob(job.jobId)
        #expect(snap.cancelRequested)
        let t = ContinuousClock.now
        let done = try d.waitStatus(job.jobId, .cancelled)
        #expect(ContinuousClock.now - t < .seconds(3), "cancel must not wait for the subprocess")
        #expect(done.error?.code == .cancelled)
        #expect(waitUntil(.seconds(3)) { !processAlive(brewPid) }, "the runner must kill the subprocess it owns")
        #expect(errorCode { try d.jobResult(job.jobId) }?.code == .jobFailed)
        #expect(try d.cancelJob(job.jobId).status == .cancelled)
    }

    @Test func slowDiscoveryDoesNotBlockOtherCallers() throws {
        let env = try Env(.hang)
        let d = try env.start()
        defer { d.shutdown() }
        let id = try d.startJob(scanSpec(env)).jobId
        let guardPid = PidGuard(try env.waitForBrewPid())
        defer { withExtendedLifetime(guardPid) {} }
        for _ in 0..<5 {
            let t = ContinuousClock.now
            #expect(try d.call(.ping) == .pong)
            _ = try d.listJobs()
            #expect(ContinuousClock.now - t < .milliseconds(500))
        }
        _ = try d.cancelJob(id)
    }

    @Test func unknownJobAndUnfinishedResultAreTypedErrors() throws {
        let env = try Env(.hang)
        let d = try env.start()
        defer { d.shutdown() }
        #expect(errorCode { try d.jobStatus("j-nope") }?.code == .jobNotFound)
        let id = try d.startJob(scanSpec(env)).jobId
        let guardPid = PidGuard(try env.waitForBrewPid())
        defer { withExtendedLifetime(guardPid) {} }
        #expect(errorCode { try d.jobResult(id) }?.code == .jobNotFinished)
        _ = try d.cancelJob(id)
    }

    @Test func activeJobLimitReturnsBusy() throws {
        let env = try Env(.hang)
        var cfg = env.config()
        cfg.jobs.maxActive = 1
        let d = try env.start(cfg)
        defer { d.shutdown() }
        let id = try d.startJob(scanSpec(env)).jobId
        let guardPid = PidGuard(try env.waitForBrewPid())
        defer { withExtendedLifetime(guardPid) {} }
        #expect(errorCode { try d.startJob(scanSpec(env)) }?.code == .busy)
        _ = try d.cancelJob(id)
    }

    @Test func shutdownCancelsRunningJobsAndCleansUpSubprocesses() throws {
        let env = try Env(.hang)
        let d = try env.start()
        let id = try d.startJob(scanSpec(env)).jobId
        let brewPid = try env.waitForBrewPid()
        let guardPid = PidGuard(brewPid)
        defer { withExtendedLifetime(guardPid) {} }
        #expect(try d.call(.shutdown) == .shuttingDown)
        d.shutdown()
        #expect(waitUntil(.seconds(1)) { !processAlive(brewPid) }, "shutdown must stop job subprocesses")
        // (Rust also asserts the socket file is removed; there is no socket under XPC.)
        let journal = readText(env.layout.journal)
        #expect(journal.contains(id) && journal.contains("\"cancelled\""), "\(journal)")
    }

    @Test func startJobAfterShutdownRequestIsRefused() throws {
        let env = try Env(.fast)
        let d = try env.start()
        defer { d.shutdown() }
        #expect(try d.call(.shutdown) == .shuttingDown)
        #expect(errorCode { try d.startJob(scanSpec(env)) }?.code == .shuttingDown)
        // After the host runs shutdown(), the job manager refuses too (plan jobs included).
        d.shutdown()
        let input = PlanInput(manifest: env.tmp.appending("m.toml"), home: env.home)
        #expect(errorCode { try d.planCreate(input) }?.code == .shuttingDown)
    }
}
