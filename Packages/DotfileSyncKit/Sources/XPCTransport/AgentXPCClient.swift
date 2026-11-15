// XPC client for the agent: replaces crates/dotfilesync-protocol/src/client.rs.

import Darwin
import Foundation
import IPC
import Synchronization
import System
import XPC

/// Why a call to the agent failed at the transport level (typed agent errors arrive as
/// `Outcome.err` instead).
public enum AgentXPCClientError: Error, Sendable, CustomStringConvertible {
    /// No agent is reachable. The CLI should fall back to standalone mode.
    case notRunning(reason: String)
    /// The data directory is unsafe (symlink, wrong owner, group/other permissions).
    case dataDir(PathError)
    /// The process answering is not running as the current user.
    case impostorAgent(agentUid: UInt32, expected: UInt32)
    /// The connection dropped after it had worked (agent crashed or exited).
    case connectionInterrupted(reason: String)
    /// The agent sent something this client cannot understand.
    case protocolViolation(String)

    public var description: String {
        switch self {
        case let .notRunning(reason): return "dotfilesync agent is not running (\(reason))"
        case let .dataDir(error): return error.description
        case let .impostorAgent(agentUid, expected):
            return "the agent is running as uid \(agentUid), not the current user (uid \(expected)); refusing to talk to it"
        case let .connectionInterrupted(reason): return "lost the connection to the dotfilesync agent: \(reason)"
        case let .protocolViolation(message): return "unexpected message from the dotfilesync agent: \(message)"
        }
    }

    /// True for ``notRunning(reason:)``.
    public var isNotRunning: Bool {
        if case .notRunning = self { return true }
        return false
    }
}

/// A connection to the per-user agent.
///
/// Calls block the calling thread until the agent replies; do not call from the main thread of
/// a UI app. Safe to use from several threads at once.
public final class AgentXPCClient: Sendable {
    private let session: XPCSession
    /// Watches in flight, by client-assigned watch id. Each callback runs on the XPC queue.
    private let watches = Mutex<[UInt64: @Sendable (IPC.Notification) -> Bool]>([:])
    private let nextWatchId = Atomic<UInt64>(1)
    /// Set after the first successful reply; distinguishes "not running" from "went away".
    private let connected = Atomic<Bool>(false)
    private let expectedUid = geteuid()

    /// Connects to the agent's launchd Mach service.
    ///
    /// Like the Rust client, first verifies (never creates or repairs) the data directories:
    /// a missing root or state dir means the agent never ran (``AgentXPCClientError/notRunning(reason:)``);
    /// a symlinked, foreign-owned or group/other-accessible one is refused
    /// (``AgentXPCClientError/dataDir(_:)``).
    public convenience init(
        machService: String = AGENT_MACH_SERVICE,
        layout: DataLayout
    ) throws(AgentXPCClientError) {
        try Self.checkDataDirs(layout)
        try self.init { handler throws in
            try XPCSession(machService: machService, incomingMessageHandler: handler)
        }
    }

    /// Connects to an anonymous listener endpoint (tests, or an endpoint handed over by the app).
    /// Pass `layout` to apply the same data-directory checks as ``init(machService:layout:)``.
    public convenience init(endpoint: XPCEndpoint, layout: DataLayout? = nil) throws(AgentXPCClientError) {
        if let layout {
            try Self.checkDataDirs(layout)
        }
        try self.init { handler throws in
            try XPCSession(endpoint: endpoint, incomingMessageHandler: handler)
        }
    }

    private init(
        _ make: (@escaping @Sendable (XPCDictionary) -> XPCDictionary?) throws -> XPCSession
    ) throws(AgentXPCClientError) {
        // `watches` must be reachable from the handler before the session exists, so the handler
        // captures a box that is filled in right after creation.
        let box = WatchTable()
        do {
            session = try make { message in box.route(message) }
        } catch {
            throw .notRunning(reason: String(describing: error))
        }
        box.client.withLock { $0 = WeakClient(self) }
    }

    deinit {
        session.cancel(reason: "client closed")
    }

    /// Closes the connection. In-flight calls fail; jobs on the agent keep running.
    public func close() {
        session.cancel(reason: "client closed")
    }

    /// Verifies the data directories without creating them.
    public static func checkDataDirs(_ layout: DataLayout) throws(AgentXPCClientError) {
        for dir in [layout.root, layout.stateDir] {
            let state: DirState
            do {
                state = try checkPrivateDir(dir)
            } catch {
                throw .dataDir(error)
            }
            if state == .missing {
                throw .notRunning(reason: "data directory does not exist")
            }
        }
    }

    // MARK: - Requests

    /// Sends one request and returns the agent's outcome. `watch_job` is accepted but its
    /// notifications are discarded; use ``watch(jobId:sinceSeq:onNotification:)`` to see them.
    public func send(_ request: Request) throws(AgentXPCClientError) -> Outcome {
        guard let json = encodeJSON(request) else {
            throw .protocolViolation("cannot encode request")
        }
        return try send(json: Data(json.utf8))
    }

    /// Sends a raw request body (the IPC JSON `{"op": …, "params": …}`). The agent validates it,
    /// so malformed or oversized bodies come back as typed `Outcome.err` values.
    public func send(json: Data) throws(AgentXPCClientError) -> Outcome {
        var message = XPCDictionary()
        message[WireKey.request] = String(decoding: json, as: UTF8.self)
        let reply = try roundTrip(message)
        return try decodeOutcome(reply)
    }

    /// Streams progress for `jobId` (Rust `watch_job`).
    ///
    /// `onNotification` receives every progress event in order and periodic heartbeats, on an
    /// XPC queue. Return `false` to stop watching; the job keeps running and this returns `nil`.
    /// Otherwise returns the final outcome (`.ok(.job(snapshot))` once the job is terminal, or
    /// `.err` for an unknown job). Closing the client mid-watch does not cancel the job.
    public func watch(
        jobId: String,
        sinceSeq: UInt64 = 0,
        onNotification: @escaping @Sendable (IPC.Notification) -> Bool
    ) throws(AgentXPCClientError) -> Outcome? {
        guard let json = encodeJSON(Request.watchJob(jobId: jobId, sinceSeq: sinceSeq)) else {
            throw .protocolViolation("cannot encode request")
        }
        let id = nextWatchId.add(1, ordering: .relaxed).oldValue
        watches.withLock { $0[id] = onNotification }
        defer { _ = watches.withLock { $0.removeValue(forKey: id) } }
        var message = XPCDictionary()
        message[WireKey.request] = json
        message[WireKey.watchId] = id
        let reply = try roundTrip(message)
        if reply[WireKey.watchStopped] == true {
            return nil
        }
        return try decodeOutcome(reply)
    }

    fileprivate func deliver(_ message: XPCDictionary) -> XPCDictionary {
        var ack = XPCDictionary()
        guard let id: UInt64 = message[WireKey.watchId],
              let json: String = message[WireKey.notification],
              let notification = try? JSONDecoder().decode(IPC.Notification.self, from: Data(json.utf8)),
              let callback = watches.withLock({ $0[id] })
        else {
            ack[WireKey.proceed] = false
            return ack
        }
        ack[WireKey.proceed] = callback(notification)
        return ack
    }

    private func roundTrip(_ message: XPCDictionary) throws(AgentXPCClientError) -> XPCDictionary {
        let reply: XPCDictionary
        do {
            reply = try session.sendSync(message: message)
        } catch {
            let reason = String(describing: error)
            if connected.load(ordering: .relaxed) && !reason.contains("lookup") {
                throw .connectionInterrupted(reason: reason)
            }
            throw .notRunning(reason: reason)
        }
        // Same check the Rust client made with peer credentials on the socket. A reply whose
        // sender cannot be identified is refused, not trusted.
        guard let agentUid = peerEuid(of: reply) else {
            throw .protocolViolation("cannot determine which user the agent runs as; refusing to talk to it")
        }
        if agentUid != expectedUid {
            throw .impostorAgent(agentUid: agentUid, expected: expectedUid)
        }
        connected.store(true, ordering: .relaxed)
        return reply
    }

    private func decodeOutcome(_ reply: XPCDictionary) throws(AgentXPCClientError) -> Outcome {
        guard let json: String = reply[WireKey.outcome] else {
            throw .protocolViolation("reply has no '\(WireKey.outcome)'")
        }
        do {
            return try JSONDecoder().decode(Outcome.self, from: Data(json.utf8))
        } catch {
            throw .protocolViolation("undecodable outcome: \(error)")
        }
    }
}

/// Weak reference so the session's handler does not keep the client alive.
private struct WeakClient: @unchecked Sendable {
    // Only read through `WatchTable.client`'s mutex; `AgentXPCClient` itself is Sendable.
    weak var value: AgentXPCClient?
    init(_ value: AgentXPCClient) { self.value = value }
}

/// Routes incoming notifications to the client that owns the session.
private final class WatchTable: Sendable {
    let client = Mutex<WeakClient?>(nil)

    func route(_ message: XPCDictionary) -> XPCDictionary? {
        guard let target = client.withLock({ $0?.value }) else {
            var ack = XPCDictionary()
            ack[WireKey.proceed] = false
            return ack
        }
        return target.deliver(message)
    }
}
