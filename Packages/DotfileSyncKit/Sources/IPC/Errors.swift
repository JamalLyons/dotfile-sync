// Port of the error types in crates/dotfilesync-protocol/src/messages.rs.

import Core

/// Machine-readable error categories. Unknown codes from newer agents decode as ``unknown``.
public enum ErrorCode: String, Codable, Sendable, Hashable, CaseIterable {
    case incompatibleVersion = "incompatible_version"
    case unauthorized
    case malformedRequest = "malformed_request"
    case frameTooLarge = "frame_too_large"
    case handshakeRequired = "handshake_required"
    case unknownOperation = "unknown_operation"
    case unsupportedOperation = "unsupported_operation"
    case invalidParams = "invalid_params"
    case jobNotFound = "job_not_found"
    case jobNotFinished = "job_not_finished"
    case jobFailed = "job_failed"
    case busy
    case shuttingDown = "shutting_down"
    case `internal`
    case planNotFound = "plan_not_found"
    case approvalRejected = "approval_rejected"
    /// An error code introduced by a newer agent (serde `#[serde(other)]`).
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ErrorCode(rawValue: raw) ?? .unknown
    }
}

/// A typed request failure. `details` is optional structured context (e.g. `{"reason": …}`).
public struct ProtocolError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String
    public var details: AnyJSON?

    /// Creates an error without details.
    public init(_ code: ErrorCode, _ message: String) {
        self.code = code
        self.message = message
        self.details = nil
    }

    /// Returns a copy carrying `details`.
    public func withDetails(_ details: JSONValue) -> ProtocolError {
        var copy = self
        copy.details = AnyJSON(details)
        return copy
    }

    /// The `details.reason` string, when present.
    public var reason: String? {
        guard case let .object(members)? = details?.value else { return nil }
        for (key, value) in members where key == "reason" {
            if case let .string(s) = value { return s }
        }
        return nil
    }

    /// Rust `Display`: `"<message> (<Debug code>)"`.
    public var description: String {
        "\(message) (\(code))"
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, details
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(ErrorCode.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
        details = try c.decodeIfPresent(AnyJSON.self, forKey: .details)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(details, forKey: .details)
    }
}
