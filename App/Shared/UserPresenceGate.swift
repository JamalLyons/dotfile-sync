// User-presence check that must pass before the app asks the agent for an approval token.

import Foundation
import LocalAuthentication

/// Outcome of a user-presence check.
enum UserPresenceResult: Equatable, Sendable {
    /// The device owner authenticated (Touch ID or the login password).
    case confirmed
    /// The user cancelled or authentication failed.
    case denied(String)
    /// No authentication method is available (no Touch ID and no password policy, e.g. CI).
    case unavailable(String)
}

/// Confirms that the device owner is present. ``LocalAuthenticationGate`` in the app; tests use
/// a fake so no system prompt ever appears.
protocol UserPresenceGate: Sendable {
    func confirmUserPresence(reason: String) async -> UserPresenceResult
}

/// `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)`: Touch ID with the login password
/// as fallback.
struct LocalAuthenticationGate: UserPresenceGate {
    func confirmUserPresence(reason: String) async -> UserPresenceResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error?.localizedDescription ?? "authentication is not available on this Mac")
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .confirmed : .denied("authentication failed")
        } catch {
            return .denied(error.localizedDescription)
        }
    }
}
