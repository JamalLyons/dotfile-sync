// XPC transport for ``AgentService``: replaces the Rust Unix-socket accept loop
// (crates/dotfilesync-daemon/src/server.rs, listener.rs).
//
// Each request is answered on a worker thread so a long `watch_job` never blocks other
// requests on the same session. `watch_job` streams notifications back to the client as
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

    /// Serves on the launchd Mach service `machService` (the agent's normal mode). Requires the
    /// process to have been launched by launchd with that name in its `MachServices`.
    ///
    /// The peer requirement is installed both on the listener and on each accepted session; the
    /// session-level check is what reports rejected peers to `log`.
    public init(
        service: AgentService,
        machService: String = AGENT_MACH_SERVICE,
        policy: PeerRequirementPolicy = .sameTeam(),
        log: Logger
    ) throws(AgentXPCServerError) {
        self.service = service
        self.policy = policy
        self.log = log
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
    public init(anonymousFor service: AgentService, policy: PeerRequirementPolicy, log: Logger) throws(AgentXPCServerError) {
        self.service = service
        self.policy = policy
        self.log = log
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
                return SessionHandler(server: self, session: session)
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

    fileprivate func handle(_ message: XPCDictionary, session: XPCSession) {
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
        let watchId: UInt64? = message[WireKey.watchId]
        let pending = PendingReply(message)
        workers.async { [self] in
            let data = Data(body.utf8)
            if let watchId, data.count <= MAX_REQUEST_BYTES,
               case let .watchJob(jobId, sinceSeq)? = try? Request.decode(json: data)
            {
                let outcome = service.watch(jobId: jobId, sinceSeq: sinceSeq, callerUid: uid) { notification in
                    self.push(notification, watchId: watchId, session: session)
                }
                var reply = XPCDictionary()
                if let outcome {
                    reply[WireKey.outcome] = encodeJSON(outcome) ?? internalErrorJSON
                } else {
                    reply[WireKey.watchStopped] = true
                }
                pending.reply(reply)
                return
            }
            let outcome = service.handle(json: data, callerUid: uid)
            var reply = XPCDictionary()
            reply[WireKey.outcome] = encodeJSON(outcome) ?? internalErrorJSON
            pending.reply(reply)
        }
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
        var reply = XPCDictionary()
        reply[WireKey.outcome] = encodeJSON(outcome) ?? internalErrorJSON
        message.reply(reply)
    }
}

private let internalErrorJSON = #"{"err":{"code":"internal","message":"cannot encode outcome"}}"#

/// Per-session message handler.
private struct SessionHandler: XPCPeerHandler {
    let server: AgentXPCServer
    let session: XPCSession

    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        server.handle(message, session: session)
        // Replies are sent asynchronously from the worker thread.
        return nil
    }

    func handleCancellation(error: XPCRichError) {
        server.sessionEnded(error)
    }
}
