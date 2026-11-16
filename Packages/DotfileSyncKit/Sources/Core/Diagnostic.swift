/// Severity of a ``Diagnostic``. Encodes as a lowercase string (`"info"`, `"warning"`, `"error"`).
public enum DiagnosticSeverity: String, Codable, Sendable, Hashable {
    case info
    case warning
    case error
}

/// A user-facing message attached to a scan, parse, or comparison result.
///
/// JSON shape: `{"severity": ..., "message": ..., "detail": ...}`; `detail` is omitted when nil.
public struct Diagnostic: Codable, Sendable, Hashable {
    public var severity: DiagnosticSeverity
    public var message: String
    public var detail: String?

    public init(severity: DiagnosticSeverity, message: String, detail: String? = nil) {
        self.severity = severity
        self.message = message
        self.detail = detail
    }

    public static func info(_ message: String) -> Diagnostic {
        Diagnostic(severity: .info, message: message)
    }

    public static func warning(_ message: String) -> Diagnostic {
        Diagnostic(severity: .warning, message: message)
    }

    public static func error(_ message: String) -> Diagnostic {
        Diagnostic(severity: .error, message: message)
    }

    public func withDetail(_ detail: String) -> Diagnostic {
        var copy = self
        copy.detail = detail
        return copy
    }
}
