// The agent-side user-presence gate on approvals and the cap on concurrent watches.

import Agent
import Core
import Dispatch
import Foundation
import IPC
import Synchronization
import Testing

/// Answers with `result` after `release` is signalled (immediately when `blocking` is false),
/// recording every prompt.
private final class FakePresence: UserPresenceVerifier {
    let result: UserPresenceResult
    let blocking: Bool
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let reasons = Mutex<[String]>([])

    init(_ result: UserPresenceResult, blocking: Bool = false) {
        self.result = result
        self.blocking = blocking
    }

    var prompts: [String] { reasons.withLock { $0 } }

    func confirmUserPresence(reason: String) -> UserPresenceResult {
        reasons.withLock { $0.append(reason) }
        if blocking {
            entered.signal()
            release.wait()
        }
        return result
    }
}

@Suite(.serialized) struct PresenceWatchTests {
    private func plannedAgent(_ presence: FakePresence) throws -> (Env, AgentService, Plan, String) {
        let env = try Env(.fast)
        let (_, input) = try applyFixture(env)
        var config = env.config()
        config.presence = presence
        let d = try env.start(config)
        let started = try d.planCreate(input)
        _ = try d.waitTerminal(started.jobId)
        guard case let .plan(plan, planId) = try d.jobResult(started.jobId) else {
            throw TestFailure(description: "plan job did not return a plan")
        }
        return (env, d, plan, planId)
    }

    @Test func deniedPresenceRefusesApproval() throws {
        let presence = FakePresence(.denied("user cancelled"))
        let (env, d, plan, planId) = try plannedAgent(presence)
        defer { d.shutdown() }

        let refused = errorCode { try d.planApprove(planId, plan.digest) }
        #expect(refused?.code == .approvalRejected)
        #expect(refused?.reason == "user_presence")
        #expect(refused?.message.contains("user cancelled") == true, "\(String(describing: refused))")
        #expect(presence.prompts == ["apply \(plan.actions.count) dotfilesync changes to \(env.home.string)"])
    }

    @Test func unavailablePresenceRefusesApproval() throws {
        let (_, d, plan, planId) = try plannedAgent(FakePresence(.unavailable("no biometrics or password")))
        defer { d.shutdown() }
        #expect(errorCode { try d.planApprove(planId, plan.digest) }?.reason == "user_presence")
    }

    @Test func tamperedDigestNeverPrompts() throws {
        let presence = FakePresence(.confirmed)
        let (_, d, _, planId) = try plannedAgent(presence)
        defer { d.shutdown() }
        #expect(errorCode { try d.planApprove(planId, "tampered") }?.reason == "plan_mismatch")
        #expect(presence.prompts.isEmpty)
    }

    @Test func secondApprovalWhilePromptIsOpenIsBusy() throws {
        let presence = FakePresence(.confirmed, blocking: true)
        let (_, d, plan, planId) = try plannedAgent(presence)
        defer { d.shutdown() }

        let first = Mutex<Result<ApprovalGrant, ProtocolError>?>(nil)
        let thread = Thread {
            let result = Result { () throws(ProtocolError) in try d.planApprove(planId, plan.digest) }
            first.withLock { $0 = result }
        }
        thread.start()
        #expect(presence.entered.wait(timeout: .now() + 5) == .success)

        #expect(errorCode { try d.planApprove(planId, plan.digest) }?.code == .busy)

        presence.release.signal()
        #expect(waitUntil(.seconds(5)) { first.withLock { $0 } != nil })
        let grant = try #require(first.withLock { $0 }).get()
        #expect(!grant.token.isEmpty)
        #expect(presence.prompts.count == 1)
    }

    @Test func watchesBeyondTheLimitAreBusy() throws {
        let env = try Env(.slow(1.0))
        var config = env.config()
        config.jobs.maxWatches = 1
        let d = try env.start(config)
        defer { d.shutdown() }
        let job = try d.startJob(scanSpec(env))

        let watching = DispatchSemaphore(value: 0)
        let finished = Mutex<JobSnapshot?>(nil)
        let thread = Thread {
            let outcome = d.watch(jobId: job.jobId, sinceSeq: 0) { _ in
                watching.signal()
                return true
            }
            if case let .ok(.job(snapshot))? = outcome {
                finished.withLock { $0 = snapshot }
            }
        }
        thread.start()
        #expect(watching.wait(timeout: .now() + 5) == .success)

        let second = d.watch(jobId: job.jobId, sinceSeq: 0) { _ in true }
        guard case let .err(error)? = second else {
            Issue.record("second watch was not refused: \(String(describing: second))")
            return
        }
        #expect(error.code == .busy)

        #expect(waitUntil(.seconds(10)) { finished.withLock { $0 } != nil })
        // The slot is free again once the first watch ends.
        #expect(try d.watchJob(job.jobId, 0).status == .succeeded)
    }
}
