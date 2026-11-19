// In-process XPC round trips: anonymous listener + endpoint, no launchd. The test runner is
// ad-hoc signed, so the TEST-ONLY `.insecureAnySigner` policy is used (except in the test that
// checks the same-team requirement rejects such a peer).

import Agent
import Core
import Darwin
import Foundation
import IPC
import Synchronization
import System
import Testing
import XPC
@testable import XPCTransport

private func scanSpec(_ env: Env) -> JobSpec {
    .scan(ScanInput(manifest: nil, home: env.home, repoRoot: nil, profile: nil))
}

/// A running agent behind an anonymous XPC listener.
private final class Harness {
    let env: Env
    let service: AgentService
    let server: AgentXPCServer
    let log: Logger

    init(
        _ mode: Brew,
        policy: PeerRequirementPolicy = .insecureAnySigner,
        ownerUid: UInt32 = geteuid(),
        watchLimits: WatchLimits? = nil
    ) throws {
        env = try Env(mode)
        var config = env.config()
        config.ownerUid = ownerUid
        service = try env.start(config)
        log = try Logger(path: env.layout.logsDir.appending("xpc.log"), maxBytes: 64 * 1024, keep: 1)
        server = try AgentXPCServer(anonymousFor: service, policy: policy, watchLimits: watchLimits, log: log)
    }

    func client() throws -> AgentXPCClient {
        guard let endpoint = server.endpoint else { throw TestFailure(description: "no endpoint") }
        return try AgentXPCClient(endpoint: endpoint, layout: env.layout, policy: .insecureAnySigner)
    }

    deinit {
        server.cancel()
        service.shutdown()
    }
}

private func response(_ client: AgentXPCClient, _ request: Request) throws -> Response {
    try client.send(request).get()
}

private func startJob(_ client: AgentXPCClient, _ spec: JobSpec) throws -> JobSnapshot {
    guard case let .job(j) = try response(client, .startJob(spec: spec)) else {
        throw TestFailure(description: "expected job")
    }
    return j
}

private func jobStatus(_ client: AgentXPCClient, _ id: String) throws -> JobSnapshot {
    guard case let .job(j) = try response(client, .jobStatus(jobId: id)) else {
        throw TestFailure(description: "expected job")
    }
    return j
}

private func errorOf(_ outcome: Outcome) -> ProtocolError? {
    if case let .err(e) = outcome { return e }
    return nil
}

@Suite(.serialized) struct XPCRoundTripTests {
    @Test func pingAndDaemonInfo() throws {
        let h = try Harness(.fast)
        let c = try h.client()
        #expect(try response(c, .ping) == .pong)
        guard case let .daemonInfo(info) = try response(c, .daemonInfo) else {
            Issue.record("expected daemon_info")
            return
        }
        #expect(info.pid == UInt32(getpid()))
        #expect(info.protocolVersion == PROTOCOL_VERSION)
        #expect(info.dataDir == h.env.layout.root)
    }

    @Test func configTreeRoundTripsOverXPC() throws {
        let h = try Harness(.fast)
        let manifest = h.env.tmp.appending("dotfilesync.toml")
        let fish = h.env.home.appending(".config/fish")
        try FileManager.default.createDirectory(atPath: fish.string, withIntermediateDirectories: true)
        try "set -g fish_greeting\n".write(toFile: fish.appending("config.fish").string, atomically: true, encoding: .utf8)
        try "schema_version = 1\n".write(toFile: manifest.string, atomically: true, encoding: .utf8)

        guard case let .configTree(tree) = try response(h.client(), .configTree(manifest: manifest, home: h.env.home)) else {
            Issue.record("expected a config tree")
            return
        }
        #expect(tree.root.aggregate?.unmanaged == 1)
        #expect(!tree.truncated)
    }

    @Test func scanJobWatchedToCompletionOverXPC() throws {
        let h = try Harness(.slow(0.4))
        let c = try h.client()
        let job = try startJob(c, scanSpec(h.env))
        let seen = Mutex<[IPC.Notification]>([])
        let outcome = try c.watch(jobId: job.jobId) { n in
            seen.withLock { $0.append(n) }
            return true
        }
        guard case let .job(final)?? = try? outcome.map({ try $0.get() }) else {
            Issue.record("watch did not return a job: \(String(describing: outcome))")
            return
        }
        #expect(final.status == .succeeded)
        let notes = seen.withLock { $0 }
        let seqs = notes.compactMap { n -> UInt64? in
            if case let .progress(id, e) = n, id == job.jobId { return e.seq }
            return nil
        }
        #expect(!seqs.isEmpty)
        #expect(seqs == seqs.sorted(), "progress arrives in order")
        #expect(Set(seqs).count == seqs.count, "no duplicates")
        #expect(seqs.last == final.latestSeq)
        // heartbeatInterval is 200 ms and brew sleeps 400 ms: at least one heartbeat.
        #expect(notes.contains(.heartbeat))
        guard case .jobResult = try response(c, .jobResult(jobId: job.jobId)) else {
            Issue.record("expected job_result")
            return
        }
    }

    @Test func cancelOverXPCKillsTheBrewChild() throws {
        let h = try Harness(.hang)
        let c = try h.client()
        let job = try startJob(c, scanSpec(h.env))
        let pid = try h.env.waitForBrewPid()
        let guardPid = PidGuard(pid)
        #expect(processAlive(pid))
        guard case .job = try response(c, .cancelJob(jobId: job.jobId)) else {
            Issue.record("expected job")
            return
        }
        #expect(waitUntil(.seconds(10)) { (try? jobStatus(c, job.jobId).status) == .cancelled })
        #expect(waitUntil(.seconds(10)) { !processAlive(pid) }, "fake brew must die")
        _ = guardPid
    }

    @Test func clientDisconnectMidWatchDoesNotCancelTheJob() throws {
        let h = try Harness(.slow(1.5))
        let watcher = try h.client()
        let job = try startJob(watcher, scanSpec(h.env))
        let gotOne = Atomic<Bool>(false)
        let finished = Atomic<Bool>(false)
        let thread = Thread {
            _ = try? watcher.watch(jobId: job.jobId) { _ in
                gotOne.store(true, ordering: .relaxed)
                return true
            }
            finished.store(true, ordering: .relaxed)
        }
        thread.start()
        #expect(waitUntil(.seconds(5)) { gotOne.load(ordering: .relaxed) })
        watcher.close()
        #expect(waitUntil(.seconds(5)) { finished.load(ordering: .relaxed) }, "watch returns after close")

        let other = try h.client()
        #expect(waitUntil(.seconds(15)) { (try? jobStatus(other, job.jobId).status) == .succeeded })
        let j = try jobStatus(other, job.jobId)
        #expect(!j.cancelRequested)
    }

    @Test func clientStoppingWatchReturnsNilAndJobContinues() throws {
        let h = try Harness(.slow(0.8))
        let c = try h.client()
        let job = try startJob(c, scanSpec(h.env))
        let outcome = try c.watch(jobId: job.jobId) { _ in false }
        #expect(outcome == nil)
        #expect(waitUntil(.seconds(15)) { (try? jobStatus(c, job.jobId).status) == .succeeded })
    }

    @Test func watchesBeyondTheCapsAreBusyAndPingStillAnswers() throws {
        let h = try Harness(.hang, watchLimits: WatchLimits(global: 3, perSession: 2))
        let first = try h.client()
        let second = try h.client()
        let job = try startJob(first, scanSpec(h.env))
        let guardPid = PidGuard(try h.env.waitForBrewPid())

        // Two watches on `first` (its cap) and one on `second` fill the global cap.
        let open = [first, first, second]
        let finished = Atomic<Int>(0)
        for client in open {
            Thread {
                _ = try? client.watch(jobId: job.jobId) { _ in true }
                finished.add(1, ordering: .relaxed)
            }.start()
        }
        #expect(waitUntil(.seconds(5)) { h.server.watchCount == 3 })

        let perSession = try first.watch(jobId: job.jobId) { _ in true }
        #expect(perSession.flatMap(errorOf)?.code == .busy, "third watch on one session: \(String(describing: perSession))")
        let global = try second.watch(jobId: job.jobId) { _ in true }
        #expect(global.flatMap(errorOf)?.code == .busy, "fourth watch overall: \(String(describing: global))")
        let third = try h.client()
        let fresh = try third.watch(jobId: job.jobId) { _ in true }
        #expect(fresh.flatMap(errorOf)?.code == .busy, "a new session is held to the global cap")

        // While every watch slot is taken, ping and cancel_job still answer promptly.
        for client in [first, second, third] {
            let started = ContinuousClock.now
            #expect(try response(client, .ping) == .pong)
            #expect(ContinuousClock.now - started < .seconds(1))
        }
        let started = ContinuousClock.now
        guard case .job = try response(third, .cancelJob(jobId: job.jobId)) else {
            Issue.record("expected job")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(1))

        // The watches end with the job and give their slots back.
        #expect(waitUntil(.seconds(10)) { finished.load(ordering: .relaxed) == 3 })
        #expect(waitUntil(.seconds(5)) { h.server.watchCount == 0 })
        let again = try third.watch(jobId: job.jobId) { _ in true }
        guard case let .job(final)?? = try? again.map({ try $0.get() }) else {
            Issue.record("watch after the slots freed: \(String(describing: again))")
            return
        }
        #expect(final.status == .cancelled)
        _ = guardPid
    }

    @Test func watchWithoutWatchIdIsRefusedWithoutBlocking() throws {
        let h = try Harness(.hang)
        let c = try h.client()
        let job = try startJob(c, scanSpec(h.env))
        let guardPid = PidGuard(try h.env.waitForBrewPid())
        let json = try #require(encodeJSON(Request.watchJob(jobId: job.jobId, sinceSeq: 0)))
        let started = ContinuousClock.now
        let outcome = try c.send(json: Data(json.utf8))
        #expect(errorOf(outcome)?.code == .malformedRequest)
        #expect(ContinuousClock.now - started < .seconds(1))
        _ = try response(c, .cancelJob(jobId: job.jobId))
        _ = guardPid
    }

    @Test func malformedAndOversizedRequestsGetTypedErrors() throws {
        let h = try Harness(.fast)
        let c = try h.client()
        #expect(errorOf(try c.send(json: Data("not json".utf8)))?.code == .malformedRequest)
        #expect(errorOf(try c.send(json: Data(#"{"op":"rm_rf"}"#.utf8)))?.code == .unknownOperation)
        let big = Data(#"{"op":"ping","params":{"pad":""#.utf8) + Data(repeating: UInt8(ascii: "a"), count: MAX_REQUEST_BYTES) + Data(#""}}"#.utf8)
        #expect(errorOf(try c.send(json: big))?.code == .frameTooLarge)
        #expect(errorOf(try c.send(.jobStatus(jobId: "nope")))?.code == .jobNotFound)
        // Unknown watch also fails cleanly through the streamed path.
        let w = try c.watch(jobId: "nope") { _ in true }
        #expect(w.flatMap(errorOf)?.code == .jobNotFound)
        // Still usable afterwards.
        #expect(try response(c, .ping) == .pong)
    }

    @Test func callerUidComesFromThePeerNotTheMessage() throws {
        // The agent's owner is a different uid than this test process: every request must be
        // refused because XPC reports our real euid, whatever the message claims.
        let h = try Harness(.fast, ownerUid: geteuid() &+ 1)
        let c = try h.client()
        let forged = Data(#"{"op":"ping","uid":\#(geteuid() &+ 1),"params":{"uid":\#(geteuid() &+ 1)}}"#.utf8)
        #expect(errorOf(try c.send(json: forged))?.code == .unauthorized)
        #expect(errorOf(try c.send(.ping))?.code == .unauthorized)
        #expect(readText(h.env.layout.logFile).contains("rejected connection from uid \(geteuid())"))

        // And with the real owner, a forged foreign uid does not lock us out either.
        let ok = try Harness(.fast)
        let c2 = try ok.client()
        let forgedOther = Data(#"{"op":"ping","uid":0,"caller_uid":0}"#.utf8)
        let outcome = try c2.send(json: forgedOther)
        // Unknown top-level fields are either ignored or refused, but never change identity.
        #expect(errorOf(outcome)?.code != .unauthorized)
        #expect(try response(c2, .ping) == .pong)
    }

    @Test func peerUidHelperReportsOwnEuid() throws {
        let uid = Mutex<UInt32?>(nil)
        let listener = XPCListener(targetQueue: nil, options: .none) { request in
            request.accept { (message: XPCDictionary) -> XPCDictionary? in
                uid.withLock { $0 = peerEuid(of: message) }
                return XPCDictionary()
            }
        }
        let session = try XPCSession(endpoint: listener.endpoint)
        _ = try session.sendSync(message: XPCDictionary())
        session.cancel(reason: "done")
        listener.cancel()
        #expect(uid.withLock { $0 } == geteuid())
    }

    @Test func sameTeamRequirementRejectsAdHocPeerAndLogsIt() throws {
        // This machine's test runner is ad-hoc signed (no team), so the shipping policy must
        // refuse it.
        let h = try Harness(.fast, policy: .sameTeam())
        let c = try h.client()
        let result = Result { () throws(AgentXPCClientError) -> Outcome in try c.send(.ping) }
        guard case .failure = result else {
            Issue.record("ad-hoc peer was accepted under the same-team policy: \(result)")
            return
        }
        let logPath = h.env.layout.logsDir.appending("xpc.log")
        #expect(waitUntil(.seconds(5)) { readText(logPath).contains("does not satisfy the code-signing requirement") })
    }

    @Test func unknownAgentUidFailsClosed() {
        #expect(throws: Never.self) { try AgentXPCClient.verifyAgentUid(geteuid(), expected: geteuid()) }
        do {
            try AgentXPCClient.verifyAgentUid(nil, expected: geteuid())
            Issue.record("nil euid accepted")
        } catch {
            guard case .impostorAgent(nil, geteuid()) = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
    }

    @Test func clientWithUnknownAgentUidSendsNoRequest() throws {
        let h = try Harness(.fast)
        guard let endpoint = h.server.endpoint else { throw TestFailure(description: "no endpoint") }
        let c = try AgentXPCClient(endpoint: endpoint, layout: h.env.layout, policy: .insecureAnySigner, peerUid: { _ in nil })
        do {
            _ = try c.send(.startJob(spec: scanSpec(h.env)))
            Issue.record("expected impostorAgent")
        } catch {
            guard case .impostorAgent(nil, _) = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        // Only the identity probe (`ping`) reached the agent: no job was started.
        let trusted = try h.client()
        guard case let .jobs(jobs) = try response(trusted, .listJobs) else {
            throw TestFailure(description: "expected jobs")
        }
        #expect(jobs.isEmpty, "\(jobs)")
    }

    @Test func releasePolicyRefusesAgentWithoutTheAgentSignature() throws {
        // The in-process agent is ad-hoc signed (no team), so it cannot satisfy the shipping
        // requirement (same team + `com.jamallyons.dotfilesync.dotfilesyncd`).
        let h = try Harness(.fast)
        guard let endpoint = h.server.endpoint else { throw TestFailure(description: "no endpoint") }
        let c = try AgentXPCClient(endpoint: endpoint, layout: h.env.layout, policy: .sameTeam())
        #expect(c.policy == .sameTeam(signingIdentifier: AGENT_SIGNING_IDENTIFIER))
        do {
            _ = try c.send(.startJob(spec: scanSpec(h.env)))
            Issue.record("ad-hoc agent was trusted under the release policy")
        } catch {
            guard case .untrustedAgent = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        let trusted = try h.client()
        guard case let .jobs(jobs) = try response(trusted, .listJobs) else {
            throw TestFailure(description: "expected jobs")
        }
        #expect(jobs.isEmpty, "the request never reached the agent: \(jobs)")
        // The debug policy accepts the same agent.
        #expect(try response(trusted, .ping) == .pong)
    }

    @Test func livePolicyIgnoresTheDebugOverrideUnlessSet() {
        #expect(AgentRequirementPolicy.live(environment: [:]) == .sameTeam())
        #expect(AgentRequirementPolicy.live(environment: ["DOTFILESYNC_INSECURE_ANY_AGENT": "0"]) == .sameTeam())
        #if DEBUG
        #expect(AgentRequirementPolicy.live(environment: ["DOTFILESYNC_INSECURE_ANY_AGENT": "1"]) == .insecureAnySigner)
        #else
        #expect(AgentRequirementPolicy.live(environment: ["DOTFILESYNC_INSECURE_ANY_AGENT": "1"]) == .sameTeam())
        #endif
    }

    @Test func notificationsBeforeTheIdentityProbeAreIgnored() throws {
        // A peer that pushes a watch notification before answering the probe must not reach
        // the watch callback.
        let callbackRan = Mutex(false)
        let listener = XPCListener(targetQueue: nil, options: .none) { request in
            request.accept { (session: XPCSession) -> PushFirstHandler in PushFirstHandler(session: session) }
        }
        defer { listener.cancel() }
        let c = try AgentXPCClient(endpoint: listener.endpoint, layout: nil, policy: .insecureAnySigner, peerUid: { _ in nil })
        let result = Result { () throws(AgentXPCClientError) -> Outcome? in
            try c.watch(jobId: "j-1") { _ in
                callbackRan.withLock { $0 = true }
                return true
            }
        }
        guard case .failure(.impostorAgent(nil, _)) = result else {
            Issue.record("expected impostorAgent, got \(result)")
            return
        }
        #expect(!callbackRan.withLock { $0 }, "a notification from an unverified peer ran the callback")
    }

    @Test func endpointGoneIsNotRunning() throws {
        let h = try Harness(.fast)
        guard let endpoint = h.server.endpoint else { throw TestFailure(description: "no endpoint") }
        h.server.cancel()
        let c = try AgentXPCClient(endpoint: endpoint, policy: .insecureAnySigner)
        do {
            _ = try c.send(.ping)
            Issue.record("expected failure")
        } catch {
            #expect(error.isNotRunning, "\(error)")
        }
    }

    @Test func machServiceThatDoesNotExistIsNotRunning() throws {
        let env = try Env(.fast)
        try env.layout.ensurePrivateDirs()
        do {
            let c = try AgentXPCClient(machService: "com.jamallyons.dotfilesync.test.absent.\(getpid())", layout: env.layout)
            _ = try c.send(.ping)
            Issue.record("expected notRunning")
        } catch {
            #expect(error.isNotRunning, "\(error)")
        }
    }

    // Client half of ipc_security_tests `refuses_permissive_or_symlinked_data_dir_and_client_refuses_too`.
    @Test func clientRefusesPermissiveOrSymlinkedDataDir() throws {
        let env = try Env(.fast)
        // Missing is accepted (launchd starts the agent, which creates it) and never created
        // by the client.
        try AgentXPCClient.checkDataDirs(env.layout)
        #expect((try? checkPrivateDir(env.layout.root)) == .missing)

        try env.layout.ensurePrivateDirs()
        try AgentXPCClient.checkDataDirs(env.layout)

        chmod(env.layout.root.string, 0o755)
        do {
            _ = try AgentXPCClient(machService: AGENT_MACH_SERVICE, layout: env.layout)
            Issue.record("permissive dir accepted")
        } catch {
            guard case let .dataDir(e) = error, case .tooPermissive = e else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        #expect(modeOf(env.layout.root) == 0o755, "client never repairs permissions")
        chmod(env.layout.root.string, 0o700)

        let link = env.tmp.appending("link")
        symlink(env.layout.root.string, link.string)
        let linked = DataLayout(root: link)
        do {
            try AgentXPCClient.checkDataDirs(linked)
            Issue.record("symlink accepted")
        } catch {
            guard case let .dataDir(e) = error, case .symlink = e else {
                Issue.record("wrong error \(error)")
                return
            }
        }
    }
}

/// Test peer: sends a `watch_id` 1 notification before replying to each message.
private struct PushFirstHandler: XPCPeerHandler {
    let session: XPCSession

    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        var note = XPCDictionary()
        note[WireKey.watchId] = UInt64(1)
        note[WireKey.notification] = encodeJSON(IPC.Notification.heartbeat)
        _ = try? session.sendSync(message: note)
        var reply = XPCDictionary()
        reply[WireKey.outcome] = encodeJSON(Outcome.ok(.pong))
        return reply
    }
}
