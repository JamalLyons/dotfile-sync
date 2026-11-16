// User-presence check the agent runs before it issues an approval token. Because it runs in the
// agent, every client that passes the XPC peer check (the app, the CLI) needs Touch ID or the
// login password to get a token; a client cannot skip it.

import Dispatch
import Foundation
import LocalAuthentication
import Synchronization

/// Outcome of a user-presence check.
public enum UserPresenceResult: Sendable, Equatable {
    /// The device owner authenticated (Touch ID or the login password).
    case confirmed
    /// The user cancelled or authentication failed.
    case denied(String)
    /// No authentication method is available.
    case unavailable(String)
}

/// Confirms that the device owner is present.
public protocol UserPresenceVerifier: Sendable {
    /// Blocks until the user answers. `reason` completes the system sentence
    /// "dotfilesyncd is trying to …".
    func confirmUserPresence(reason: String) -> UserPresenceResult
}

/// `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)`: Touch ID with the login password
/// as fallback. The system shows the prompt on behalf of the agent.
public struct LocalAuthenticationPresence: UserPresenceVerifier {
    public init() {}

    public func confirmUserPresence(reason: String) -> UserPresenceResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error?.localizedDescription ?? "authentication is not available on this Mac")
        }
        let answer = PresenceAnswer()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            answer.set(ok ? .confirmed : .denied(error?.localizedDescription ?? "authentication failed"))
        }
        return answer.wait()
    }
}

/// Confirms without asking. Tests only: no shipping code path constructs it.
public struct SkipUserPresence: UserPresenceVerifier {
    public init() {}

    public func confirmUserPresence(reason: String) -> UserPresenceResult {
        .confirmed
    }
}

/// Hands the LocalAuthentication callback's result to the waiting request thread.
private final class PresenceAnswer: Sendable {
    private let result = Mutex<UserPresenceResult?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func set(_ value: UserPresenceResult) {
        result.withLock { $0 = value }
        done.signal()
    }

    func wait() -> UserPresenceResult {
        done.wait()
        return result.withLock { $0 } ?? .denied("authentication failed")
    }
}
