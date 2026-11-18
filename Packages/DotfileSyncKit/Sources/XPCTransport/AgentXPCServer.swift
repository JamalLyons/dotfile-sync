// XPC transport for ``AgentService``: replaces the Rust Unix-socket accept loop
// (crates/dotfilesync-daemon/src/server.rs, listener.rs).
//
// Each request is answered off the session queue so a long `watch_job` never blocks other
// requests on the same session. Watches are admitted against a per-session and a global cap
// before they start (beyond either, the reply is `busy`) and run on their own threads, never on
// the shared worker queue, so open watches cannot starve `ping` or `cancel_job`. `watch_job` streams notifications back to the client as
// synchronous XPC messages on the same session (one ack per notification), which preserves
// ordering and back-pressure and lets the agent notice a vanished client: the send fails, the
// watch stops, and the job keeps running (exactly `AgentService.watch` semantics).

import Agent
import Darwin
import Dispatch
import Foundation
import IPC
import LightweightCodeRequirements
import Synchronization
import XPC

/// Signing identifiers of the processes allowed to talk to the agent: the app (its bundle
/// identifier) and the embedded CLI (`--identifier` in App/Scripts/embed-agent-binaries.sh).
public let AGENT_CLIENT_SIGNING_IDENTIFIERS = ["com.jamallyons.dotfilesync", "com.jamallyons.dotfilesync.dotfilesync"]

/// Which code-signing requirement a connecting process must satisfy.
public enum PeerRequirementPolicy: Sendable, Equatable, CustomStringConvertible {
    /// Shipping default: the peer must be signed by the same team as the agent and carry one of
    /// `signingIdentifiers`. Another program signed by the same team is refused.
    case sameTeam(signingIdentifiers: [String] = AGENT_CLIENT_SIGNING_IDENTIFIERS)
    /// Development/testing only (explicit opt-in): no code-signing check. Ad-hoc-signed local
    /// builds have no team identifier and would fail ``sameTeam(signingIdentifiers:)``. The
    /// same-UID check still applies to every request.
    case insecureAnySigner

    public var description: String {
        switch self {
        case let .sameTeam(ids): return "same-team(\(ids.joined(separator: ", ")))"
        case .insecureAnySigner: return "any-signer (development only)"
        }
    }

    func requirement() throws(AgentXPCServerError) -> XPCPeerRequirement? {
        switch self {
        case let .sameTeam(ids):
            guard !ids.isEmpty else {
                throw AgentXPCServerError(description: "the same-team peer policy needs at least one signing identifier")
            }
            do {
                return .codeRequirement(try ProcessCodeRequirement.allOf {
                    TeamIdentifierMatchesCurrentProcess()
                    SigningIdentifier.in(ids)
                })
            } catch {
                throw AgentXPCServerError(description: "cannot build the peer code requirement: \(error)")
            }
        case .insecureAnySigner:
            return nil
        }
    }
}

/// Transport-level bounds on concurrent `watch_job` streams.
public struct WatchLimits: Sendable, Equatable {
    /// Open watches across all sessions. The service's ``JobLimits/maxWatches`` still applies.
    public var global: Int
    /// Open watches on one peer session.
    public var perSession: Int

    public init(global: Int = 16, perSession: Int = 4) {
        self.global = global
        self.perSession = perSession
    }
}

/// Why an ``AgentXPCServer`` could not start.
public struct AgentXPCServerError: Error, Sendable, CustomStringConvertible {
    public var description: String
}

/// Serves an ``AgentService`` over XPC.
///
/// The caller UID passed to the service is always the effective UID of the XPC peer that sent
/// the message (from the kernel audit token); nothing in the message body can change it.
public final class AgentXPCServer: Sendable {
    /// The service this server answers for.
    public let service: AgentService
    /// The code-signing policy applied to every peer session.
    public let policy: PeerRequirementPolicy
    private let requirement: XPCPeerRequirement?
    private let log: Logger
    private let workers = DispatchQueue(label: "dotfilesync.xpc.worker", attributes: .concurrent)
    /// The listener, set once during init and cleared by ``cancel()``.
    private let listener = Mutex<XPCListener?>(nil)
    private let activeSessions = Atomic<Int>(0)
    /// Bounds on concurrent watches applied before a watch gets a thread.
    public let watchLimits: WatchLimits
    private let activeWatches = Atomic<Int>(0)

    /// Serves on the launchd Mach service `machService` (the agent's normal mode). Requires the
    /// process to have been launched by launchd with that name in its `MachServices`.
    ///
    /// The peer requirement is installed both on the listener and on each accepted session; the
    /// session-level check is what reports rejected peers to `log`.
    public init(
        service: AgentService,
        machService: String = AGENT_MACH_SERVICE,
        policy: PeerRequirementPolicy = .sameTeam(),
        watchLimits: WatchLimits? = nil,
        log: Logger
    ) throws(AgentXPCServerError) {
        self.service = service
        self.policy = policy
        self.log = log
        self.watchLimits = watchLimits ?? WatchLimits(global: service.config.jobs.maxWatches)
        requirement = try policy.requirement()
        let handler = makeSessionHandler()
        do {
            let created: XPCListener
            if let requirement {
                created = try XPCListener(service: machService, requirement: requirement, incomingSessionHandler: handler)
            } else {
                created = try XPCListener(service: machService, incomingSessionHandler: handler)
            }
            listener.withLock { $0 = created }
        } catch {
            throw AgentXPCServerError(description: "cannot listen on Mach service \(machService): \(error)")
        }
        log.info("xpc: listening on Mach service \(machService) peer-requirement=\(policy)")
    }

    /// Serves on a new anonymous listener reachable only through ``endpoint``.
    ///
    /// For in-process tests and for handing an endpoint over an existing XPC channel. Tests may
    /// pass ``PeerRequirementPolicy/insecureAnySigner`` because the test runner is ad-hoc signed.
    public init(
        anonymousFor service: AgentService,
        policy: PeerRequirementPolicy,
        watchLimits: WatchLimits? = nil,
        log: Logger
    ) throws(AgentXPCServerError) {
        self.service = service
        self.policy = policy
        self.log = log
        self.watchLimits = watchLimits ?? WatchLimits(global: service.config.jobs.maxWatches)
        requirement = try policy.requirement()
        let created = XPCListener(targetQueue: nil, options: .none, incomingSessionHandler: makeSessionHandler())
        listener.withLock { $0 = created }
        log.info("xpc: listening on anonymous endpoint peer-requirement=\(policy)")
    }

    /// The endpoint of the listener, for ``AgentXPCClient/init(endpoint:)``. `nil` after ``cancel()``.
    public var endpoint: XPCEndpoint? {
        listener.withLock { $0?.endpoint }
    }

    /// Number of currently connected peer sessions.
    public var sessionCount: Int {
        activeSessions.load(ordering: .relaxed)
    }

    /// Number of `watch_job` streams currently running over XPC.
    public var watchCount: Int {
        activeWatches.load(ordering: .relaxed)
    }

    /// Stops accepting new sessions. Existing sessions end when their peers disconnect or the
    /// process exits.
    public func cancel() {
        let current = listener.withLock { held -> XPCListener? in
            let current = held
            held = nil
            return current
        }
        current?.cancel()
    }

    // MARK: - Sessions

    private func makeSessionHandler() -> @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
        { [weak self] request in
            guard let self else { return request.reject(reason: "agent is stopping") }
            return request.accept { (session: XPCSession) -> SessionHandler in
                if let requirement = self.requirement {
                    session.setPeerRequirement(requirement)
                }
                self.activeSessions.add(1, ordering: .relaxed)
                return SessionHandler(server: self, session: session, watches: SessionWatches())
            }
        }
    }

    fileprivate func sessionEnded(_ error: XPCRichError) {
        activeSessions.subtract(1, ordering: .relaxed)
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("code signing") || text.localizedCaseInsensitiveContains("forbidden") {
            log.warn("xpc: rejected peer that does not satisfy the code-signing requirement (\(policy)): \(text)")
        }
    }

    fileprivate func handle(_ message: XPCDictionary, session: XPCSession, watches: SessionWatches) {
        // Kernel-provided identity of the sender. Never taken from the message body.
        guard let uid = peerEuid(of: message) else {
            log.warn("xpc: message without a peer connection; refusing")
            let outcome = Outcome.err(ProtocolError(.unauthorized, "cannot determine the caller's identity"))
            reply(to: message, outcome: outcome)
            return
        }
        guard let body: String = message[WireKey.request] else {
            reply(to: message, outcome: .err(ProtocolError(.malformedRequest, "missing '\(WireKey.request)' string")))
            return
        }
        let data = Data(body.utf8)
        let pending = PendingReply(message)
        if let watchId: UInt64 = message[WireKey.watchId], data.count <= MAX_REQUEST_BYTES,
           case let .watchJob(jobId, sinceSeq)? = try? Request.decode(json: data)
        {
            // Admit before a thread is spent, so refused watches cost nothing and admitted
            // ones never occupy the shared worker queue.
            if let refused = admitWatch(watches) {
                pending.reply(outcomeReply(.err(refused)))
                return
            }
            let thread = Thread { [self] in
                defer { releaseWatch(watches) }
                let outcome = service.watch(jobId: jobId, sinceSeq: sinceSeq, callerUid: uid) { notification in
                    self.push(notification, watchId: watchId, session: session)
                }
                if let outcome {
                    pending.reply(outcomeReply(outcome))
                } else {
                    var reply = XPCDictionary()
                    reply[WireKey.watchStopped] = true
                    pending.reply(reply)
                }
            }
            thread.name = "dotfilesync.xpc.watch"
            thread.start()
            return
        }
        workers.async { [self] in
            pending.reply(outcomeReply(service.handle(json: data, callerUid: uid)))
        }
    }

    /// Takes a session and a global watch slot, or says why not.
    private func admitWatch(_ watches: SessionWatches) -> ProtocolError? {
        let perSession = watchLimits.perSession
        if watches.count.wrappingAdd(1, ordering: .relaxed).oldValue >= perSession {
            watches.count.subtract(1, ordering: .relaxed)
            return ProtocolError(.busy, "too many jobs are being watched on this connection (limit \(perSession)); stop a watch and try again")
        }
        let global = watchLimits.global
        if activeWatches.wrappingAdd(1, ordering: .relaxed).oldValue >= global {
            activeWatches.subtract(1, ordering: .relaxed)
            watches.count.subtract(1, ordering: .relaxed)
            return ProtocolError(.busy, "too many jobs are being watched (limit \(global)); stop a watch and try again")
        }
        return nil
    }

    private func releaseWatch(_ watches: SessionWatches) {
        activeWatches.subtract(1, ordering: .relaxed)
        watches.count.subtract(1, ordering: .relaxed)
    }

    /// Sends one notification and waits for the client's ack. `false` stops the watch.
    private func push(_ notification: IPC.Notification, watchId: UInt64, session: XPCSession) -> Bool {
        guard let json = encodeJSON(notification) else { return false }
        var message = XPCDictionary()
        message[WireKey.watchId] = watchId
        message[WireKey.notification] = json
        do {
            let ack = try session.sendSync(message: message)
            return ack[WireKey.proceed] ?? false
        } catch {
            return false
        }
    }

    private func reply(to message: XPCDictionary, outcome: Outcome) {
        message.reply(outcomeReply(outcome))
    }

    private func outcomeReply(_ outcome: Outcome) -> XPCDictionary {
        var reply = XPCDictionary()
        reply[WireKey.outcome] = encodeJSON(outcome) ?? internalErrorJSON
        return reply
    }
}

private let internalErrorJSON = #"{"err":{"code":"internal","message":"cannot encode outcome"}}"#

/// Open watches on one peer session.
private final class SessionWatches: Sendable {
    let count = Atomic<Int>(0)
}

/// Per-session message handler.
private struct SessionHandler: XPCPeerHandler {
    let server: AgentXPCServer
    let session: XPCSession
    let watches: SessionWatches

    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        server.handle(message, session: session, watches: watches)
        // Replies are sent asynchronously from the worker thread.
        return nil
    }

    func handleCancellation(error: XPCRichError) {
        server.sessionEnded(error)
    }
}
