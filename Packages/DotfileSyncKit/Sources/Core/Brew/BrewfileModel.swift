/// A Brewfile line that the static parser could not import.
///
/// JSON shape matches the Rust serde output:
/// `{"line_number": ..., "raw_line": ..., "construct_type": ..., "reason": ...}`.
public struct UnsupportedConstruct: Codable, Sendable, Equatable {
    /// 1-based line number in the Brewfile (for unclosed blocks, the line that opened the block).
    public var lineNumber: Int
    /// The original, untrimmed line text (or a synthetic description for unclosed blocks).
    public var rawLine: String
    /// Classification, e.g. `"tap"`, `"mas"`, `"bundle_extension"`, `"dynamic_ruby"`,
    /// `"malformed_syntax"`, `"unsupported_expression"`, `"unrecognized"`.
    public var constructType: String
    /// Human-readable explanation of why the line was not imported.
    public var reason: String

    public init(lineNumber: Int, rawLine: String, constructType: String, reason: String) {
        self.lineNumber = lineNumber
        self.rawLine = rawLine
        self.constructType = constructType
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case lineNumber = "line_number"
        case rawLine = "raw_line"
        case constructType = "construct_type"
        case reason
    }
}

/// Result of statically parsing a Brewfile with ``parseBrewfile(_:)``.
///
/// JSON shape matches the Rust serde output:
/// `{"formulae": [...], "casks": [...], "unsupported_constructs": [...], "diagnostics": [...]}`.
public struct BrewfileParseResult: Codable, Sendable, Equatable {
    /// Unconditional `brew` declarations, sorted by UTF-8 bytes and de-duplicated.
    public var formulae: [String]
    /// Unconditional `cask` declarations, sorted by UTF-8 bytes and de-duplicated.
    public var casks: [String]
    /// Lines that were not imported, in the order encountered (unclosed blocks last).
    public var unsupportedConstructs: [UnsupportedConstruct]
    /// Warnings and a final summary diagnostic.
    public var diagnostics: [Diagnostic]

    public init(
        formulae: [String],
        casks: [String],
        unsupportedConstructs: [UnsupportedConstruct],
        diagnostics: [Diagnostic]
    ) {
        self.formulae = formulae
        self.casks = casks
        self.unsupportedConstructs = unsupportedConstructs
        self.diagnostics = diagnostics
    }

    enum CodingKeys: String, CodingKey {
        case formulae
        case casks
        case unsupportedConstructs = "unsupported_constructs"
        case diagnostics
    }
}
