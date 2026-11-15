// XPC wire format shared by ``AgentXPCServer`` and ``AgentXPCClient``.
//
// Every message is an XPC dictionary carrying the existing IPC JSON as a UTF-8 string, so the
// JSON stays byte-compatible with the Rust protocol and with `AgentService.handle(json:)`:
//
//   client → agent   { "request": <Request JSON>, "watch_id": <uint64, only for streamed watches> }
//   agent  → client  reply { "outcome": <Outcome JSON> }  or  { "watch_stopped": true }
//   agent  → client  notification (sync, during a streamed watch)
//                    { "watch_id": <uint64>, "notification": <Notification JSON> }
//   client → agent   ack reply { "continue": <bool> }
//
// The caller's UID is never read from message content: the agent takes it from the XPC peer
// (`xpc_connection_get_euid` of the message's remote connection, i.e. the kernel audit token).

import Darwin
import Foundation
import IPC
import Synchronization
import XPC

/// Default Mach service name (also the launchd `Label`) of the per-user agent. Matches
/// `App/LaunchAgents/com.jamallyons.dotfilesync.agent.plist`.
public let AGENT_MACH_SERVICE = "com.jamallyons.dotfilesync.agent"

enum WireKey {
    static let request = "request"
    static let outcome = "outcome"
    static let watchId = "watch_id"
    static let watchStopped = "watch_stopped"
    static let notification = "notification"
    static let proceed = "continue"
}

/// The effective UID of the process that sent `message`, from its XPC peer connection.
/// `nil` when the message has no remote connection (never trusted as "owner").
func peerEuid(of message: XPCDictionary) -> UInt32? {
    message.withUnsafeUnderlyingDictionary { raw -> UInt32? in
        guard let connection = xpc_dictionary_get_remote_connection(raw) else { return nil }
        return xpc_connection_get_euid(connection)
    }
}

func encodeJSON<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// Holds a received message until the worker thread that answers it replies, exactly once.
///
/// XPC messages are reference-counted, thread-safe objects; the incoming-message handler hands
/// the message to this box and never touches it again.
final class PendingReply: Sendable {
    /// Read only inside `replied.withLock`, which also guarantees a single reply.
    nonisolated(unsafe) private let message: XPCDictionary
    private let replied = Mutex(false)

    init(_ message: XPCDictionary) {
        self.message = message
    }

    /// Sends `reply` to the held message; later calls do nothing.
    func reply(_ reply: XPCDictionary) {
        replied.withLock { done in
            guard !done else { return }
            done = true
            message.reply(reply)
        }
    }
}
