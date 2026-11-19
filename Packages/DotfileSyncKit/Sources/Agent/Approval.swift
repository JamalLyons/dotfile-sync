// Port of crates/dotfilesync-daemon/src/approval.rs: single-use approval tokens.
//
// Approving an ``ApprovalPlan`` yields an ``ApprovalToken`` bound to the core plan digest, the
// owning user (from the transport's peer identity, never a request field), the observed-state
// fingerprint and an expiry. Redeeming checks all of these and consumes the token atomically;
// a failed redemption also burns it. Only `sha256(token)` is stored, in memory; tokens are
// never journaled or logged, and an agent restart invalidates every approval.

import CryptoKit
import Synchronization

/// How long an approval stays redeemable (10 minutes).
public let APPROVAL_TTL_MS: UInt64 = 10 * 60 * 1000

/// Approval binding for a core plan. `contentDigest` is `Core.Plan.digest`.
public struct ApprovalPlan: Sendable, Equatable {
    public var planId: String
    /// Resource key used to supersede older approvals (the home the plan mutates).
    public var resource: String
    /// `Core.Plan.digest`.
    public var contentDigest: String
    /// Fingerprint of the observed state the plan was computed from.
    public var stateFingerprint: String
    public var ownerUid: UInt32

    public init(planId: String, resource: String, contentDigest: String, stateFingerprint: String, ownerUid: UInt32) {
        self.planId = planId
        self.resource = resource
        self.contentDigest = contentDigest
        self.stateFingerprint = stateFingerprint
        self.ownerUid = ownerUid
    }

    /// The digest the approval is bound to (only `contentDigest`).
    public var digest: String { contentDigest }
}

/// Opaque single-use approval token. `description`/`debugDescription` never reveal it.
public struct ApprovalToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    init(secret: String) {
        value = secret
    }

    /// Wraps a token presented by a client.
    public static func fromClient(_ value: String) -> ApprovalToken {
        ApprovalToken(secret: value)
    }

    /// The secret value, for handing to the approving client only.
    public func expose() -> String { value }

    var hash: String {
        hexString(Array(SHA256.hash(data: Array(value.utf8))))
    }

    public var description: String { "<redacted approval token>" }
    public var debugDescription: String { "ApprovalToken(<redacted>)" }
}

/// Why an approval was refused. `description` matches the Rust messages.
public enum ApprovalError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownToken
    case expired
    case alreadyUsed
    case planMismatch
    case stateChanged
    case wrongOwner
    case entropy
    /// Touch ID / password was cancelled, failed or is unavailable.
    case userPresence(String)

    public var description: String {
        switch self {
        case .unknownToken: return "approval token is unknown"
        case .expired: return "approval has expired"
        case .alreadyUsed: return "approval token was already used"
        case .planMismatch: return "plan changed after it was approved"
        case .stateChanged: return "observed state changed after the plan was approved; re-plan and approve again"
        case .wrongOwner: return "approval belongs to a different user"
        case .entropy: return "could not generate approval token"
        case let .userPresence(message): return "user presence was not confirmed: \(message)"
        }
    }

    /// Stable `details.reason` string.
    public var reason: String {
        switch self {
        case .unknownToken: return "unknown_token"
        case .expired: return "expired"
        case .alreadyUsed: return "already_used"
        case .planMismatch: return "plan_mismatch"
        case .stateChanged: return "state_changed"
        case .wrongOwner: return "wrong_owner"
        case .entropy: return "entropy"
        case .userPresence: return "user_presence"
        }
    }
}

private struct Approval {
    var resource: String
    var planDigest: String
    var ownerUid: UInt32
    var stateFingerprint: String
    var expiresAtMs: UInt64
    var consumed: Bool
}

/// In-memory approvals keyed by `sha256(token)`.
public final class ApprovalStore: Sendable, CustomStringConvertible {
    private let approvals = Mutex<[String: Approval]>([:])

    public init() {}

    /// Approves `plan` for `approverUid`, who must own it. Supersedes older approvals for the
    /// same resource and drops expired or consumed entries.
    public func issue(
        _ plan: ApprovalPlan,
        approverUid: UInt32,
        nowMs: UInt64,
        ttlMs: UInt64
    ) throws(ApprovalError) -> ApprovalToken {
        if approverUid != plan.ownerUid {
            throw .wrongOwner
        }
        let token = ApprovalToken(secret: randomHex(32))
        let (expires, overflow) = nowMs.addingReportingOverflow(ttlMs)
        approvals.withLock { map in
            map = map.filter { !$0.value.consumed && $0.value.expiresAtMs > nowMs && $0.value.resource != plan.resource }
            map[token.hash] = Approval(
                resource: plan.resource,
                planDigest: plan.digest,
                ownerUid: plan.ownerUid,
                stateFingerprint: plan.stateFingerprint,
                expiresAtMs: overflow ? UInt64.max : expires,
                consumed: false
            )
        }
        return token
    }

    /// Validates and consumes `token` for applying `plan` against `currentState`.
    /// Any outcome other than success on a known token also invalidates it.
    public func redeem(
        _ token: ApprovalToken,
        plan: ApprovalPlan,
        callerUid: UInt32,
        currentState: String?,
        nowMs: UInt64
    ) throws(ApprovalError) {
        let result: ApprovalError? = approvals.withLock { map in
            let key = token.hash
            guard var a = map[key] else { return .unknownToken }
            if a.consumed { return .alreadyUsed }
            a.consumed = true
            map[key] = a
            if nowMs >= a.expiresAtMs { return .expired }
            if callerUid != a.ownerUid || plan.ownerUid != a.ownerUid { return .wrongOwner }
            if plan.digest != a.planDigest { return .planMismatch }
            if currentState != a.stateFingerprint { return .stateChanged }
            return nil
        }
        if let result {
            throw result
        }
    }

    /// Invalidates outstanding approvals for `resource`.
    public func revokeResource(_ resource: String) {
        approvals.withLock { map in
            map = map.filter { $0.value.resource != resource }
        }
    }

    /// Invalidates every outstanding approval.
    public func revokeAll() {
        approvals.withLock { $0.removeAll() }
    }

    /// Unconsumed, unexpired approvals.
    public func liveCount(nowMs: UInt64) -> Int {
        approvals.withLock { map in
            map.values.filter { !$0.consumed && $0.expiresAtMs > nowMs }.count
        }
    }

    /// Shows only the number of entries; never a token or its hash.
    public var description: String {
        "ApprovalStore(\(approvals.withLock { $0.count }) entries)"
    }
}
