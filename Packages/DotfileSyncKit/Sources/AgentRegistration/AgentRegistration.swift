// Replaces crates/dotfilesync-daemon/src/service/** (launchctl + hand-written plist in
// ~/Library/LaunchAgents) with SMAppService. The plist ships inside the signed app bundle at
// `Contents/Library/LaunchAgents/<plistName>`, so there is no user-writable definition to
// validate, escape or protect from foreign edits.
//
// Start-at-login: the Rust service wrote `RunAtLoad=false` unless `--start-at-login` was given.
// The shipped plist has no `RunAtLoad`/`KeepAlive`; the agent is launched on demand when a
// client looks up its Mach service. Registering with SMAppService makes the definition known to
// launchd for this user (it then also appears under Login Items in System Settings, where the
// user can toggle it). There is no separate "registered but never at login" state.

import Foundation
import ServiceManagement

/// launchd plist file name inside `Contents/Library/LaunchAgents/` of the app bundle.
public let AGENT_PLIST_NAME = "com.jamallyons.dotfilesync.agent.plist"

/// Registration state of the agent, as reported to the CLI (`snake_case` JSON).
public enum AgentRegistrationStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// Not registered with launchd.
    case notRegistered = "not_registered"
    /// Registered and allowed to run.
    case enabled
    /// Registered, but the user must allow it in System Settings → General → Login Items.
    case requiresApproval = "requires_approval"
    /// The plist is not in the app bundle (e.g. running outside the signed app).
    case notFound = "not_found"
}

/// Result of ``AgentRegistering/register()``.
public enum RegisterOutcome: String, Codable, Sendable, Equatable {
    /// Newly registered.
    case registered
    /// It was already registered; nothing changed.
    case alreadyRegistered = "already_registered"
}

/// Result of ``AgentRegistering/unregister()``.
public enum UnregisterOutcome: String, Codable, Sendable, Equatable {
    case unregistered
    /// Nothing was registered; nothing changed.
    case notRegistered = "not_registered"
}

/// A registration failure.
public struct AgentRegistrationError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    /// The status at the time of failure, when known.
    public var status: AgentRegistrationStatus?

    public init(_ message: String, status: AgentRegistrationStatus? = nil) {
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

/// The low-level service operations (``SMAppServiceBackend`` in production, a fake in tests).
public protocol AgentServiceBackend: Sendable {
    var status: AgentRegistrationStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// Agent registration operations used by the CLI and the app.
public protocol AgentRegistering: Sendable {
    var status: AgentRegistrationStatus { get }
    func register() throws(AgentRegistrationError) -> RegisterOutcome
    func unregister() throws(AgentRegistrationError) -> UnregisterOutcome
    func openSystemSettingsLoginItems()
}

/// Idempotent registration on top of a backend.
///
/// - `register()` is a no-op when already `enabled` or `requiresApproval`.
/// - `unregister()` is a no-op when `notRegistered`/`notFound`. It only removes the launchd
///   registration: the data directory (state, logs, backups) and the user's dotfiles are never
///   touched.
public struct AgentRegistration: AgentRegistering {
    public let backend: any AgentServiceBackend

    /// Production registration for `plistName` in the main app bundle.
    public init(plistName: String = AGENT_PLIST_NAME) {
        backend = SMAppServiceBackend(plistName: plistName)
    }

    /// Registration over a custom backend (tests).
    public init(backend: any AgentServiceBackend) {
        self.backend = backend
    }

    public var status: AgentRegistrationStatus { backend.status }

    public func register() throws(AgentRegistrationError) -> RegisterOutcome {
        switch backend.status {
        case .enabled, .requiresApproval:
            return .alreadyRegistered
        case .notFound:
            throw AgentRegistrationError(
                "the agent's launchd definition is not in the app bundle; run dotfilesync from the installed app",
                status: .notFound
            )
        case .notRegistered:
            break
        }
        do {
            try backend.register()
        } catch {
            throw AgentRegistrationError("cannot register the agent: \(error.localizedDescription)", status: backend.status)
        }
        return .registered
    }

    public func unregister() throws(AgentRegistrationError) -> UnregisterOutcome {
        switch backend.status {
        case .notRegistered, .notFound:
            return .notRegistered
        case .enabled, .requiresApproval:
            break
        }
        do {
            try backend.unregister()
        } catch {
            throw AgentRegistrationError("cannot unregister the agent: \(error.localizedDescription)", status: backend.status)
        }
        return .unregistered
    }

    public func openSystemSettingsLoginItems() {
        backend.openSystemSettingsLoginItems()
    }
}

/// Maps `SMAppService.Status` to ``AgentRegistrationStatus``.
public func mapStatus(_ status: SMAppService.Status) -> AgentRegistrationStatus {
    switch status {
    case .notRegistered: return .notRegistered
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    case .notFound: return .notFound
    @unknown default: return .notFound
    }
}

/// The real `SMAppService.agent(plistName:)` backend. Never used by tests.
public struct SMAppServiceBackend: AgentServiceBackend {
    public let plistName: String

    public init(plistName: String) {
        self.plistName = plistName
    }

    private var service: SMAppService { SMAppService.agent(plistName: plistName) }

    public var status: AgentRegistrationStatus { mapStatus(service.status) }

    public func register() throws { try service.register() }

    public func unregister() throws { try service.unregister() }

    public func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
