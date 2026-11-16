// Test doubles. Nothing here talks to launchd, SMAppService, XPC or LocalAuthentication.

import AgentRegistration
import Core
import Foundation
import IPC
import Synchronization
import System

final class FakeRegistration: AgentRegistering {
    let state: Mutex<(status: AgentRegistrationStatus, calls: [String], failRegister: Bool)>

    init(status: AgentRegistrationStatus, failRegister: Bool = false) {
        state = Mutex((status, [], failRegister))
    }

    var calls: [String] { state.withLock { $0.calls } }
    var status: AgentRegistrationStatus { state.withLock { $0.status } }

    func register() throws(AgentRegistrationError) -> RegisterOutcome {
        let fail = state.withLock { s -> Bool in
            s.calls.append("register")
            return s.failRegister
        }
        if fail { throw AgentRegistrationError("boom", status: .notRegistered) }
        return state.withLock { s in
            if s.status == .notRegistered {
                s.status = .requiresApproval
                return .registered
            }
            return .alreadyRegistered
        }
    }

    func unregister() throws(AgentRegistrationError) -> UnregisterOutcome {
        state.withLock { s in
            s.calls.append("unregister")
            if s.status == .enabled || s.status == .requiresApproval {
                s.status = .notRegistered
                return .unregistered
            }
            return .notRegistered
        }
    }

    func openSystemSettingsLoginItems() {
        state.withLock { $0.calls.append("openLoginItems") }
    }
}

/// Scripted agent: answers by op name and records every request it receives.
final class FakeAgent: AgentClient {
    typealias Handler = @Sendable (Request) throws(AgentCallError) -> Response
    private let handler: Handler
    private let log = Mutex<[Request]>([])
    let terminal: JobSnapshot?

    init(terminal: JobSnapshot? = nil, _ handler: @escaping Handler) {
        self.handler = handler
        self.terminal = terminal
    }

    var requests: [Request] { log.withLock { $0 } }
    var ops: [String] { requests.map(\.opName) }

    func call(_ request: Request) async throws(AgentCallError) -> Response {
        log.withLock { $0.append(request) }
        return try handler(request)
    }

    func waitForJob(
        _ jobId: String,
        onProgress: @escaping @Sendable (ProgressEvent) -> Void
    ) async throws(AgentCallError) -> JobSnapshot {
        log.withLock { $0.append(.watchJob(jobId: jobId, sinceSeq: 0)) }
        onProgress(ProgressEvent(seq: 1, atMs: 1, stage: "test", message: "working"))
        return terminal ?? snapshot(jobId, .succeeded)
    }
}

func snapshot(_ id: String, _ status: JobStatus, kind: JobKind = .scan, error: JobError? = nil) -> JobSnapshot {
    JobSnapshot(
        jobId: id, kind: kind, status: status, createdAtMs: 0, latestSeq: 0,
        cancelRequested: false, fromPreviousRun: false, error: error
    )
}

func samplePlan(actions: Int) -> Plan {
    Plan(
        schema: PLAN_SCHEMA,
        profile: "work",
        manifestPath: "/fixture/dotfilesync.toml",
        home: "/fixture/home",
        repoRoot: "/fixture",
        actions: (0..<actions).map { n in
            PlanAction(
                id: String(format: "a-%03d", n + 1),
                kind: .brewInstallFormula(name: "pkg\(n)"),
                summary: "install pkg\(n)",
                risk: n == 0 ? .high : .low,
                reversible: true,
                backup: false
            )
        },
        stateFingerprint: "fp"
    )
}

/// A token value tests can search for to prove it never leaks into model state.
let SECRET_TOKEN = "tok-SECRET-do-not-leak-7f3a"
