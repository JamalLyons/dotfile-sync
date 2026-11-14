// Port of the error enums in crates/dotfilesync-core/src/manifest/{mod.rs,validation.rs}.
// `description` reproduces the Rust `Display` (thiserror `#[error]`) strings exactly.

import Foundation

/// Failure loading, parsing, serializing, validating, or resolving a manifest.
public enum ManifestError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// The manifest file could not be read. `reason` mirrors the Rust `io::Error` display,
    /// e.g. `No such file or directory (os error 2)`.
    case io(path: String, reason: String)
    /// The TOML text could not be parsed or decoded into a ``Manifest``.
    case parse(String)
    /// The manifest could not be encoded to TOML.
    case serialize(String)
    /// Validation failed: error count and the `- `-prefixed, newline-joined messages.
    case validation(Int, String)
    /// A named profile does not exist.
    case unknownProfile(name: String)
    /// An `extends` chain loops, e.g. `a -> b -> a`.
    case profileCycle(cycle: String)

    public var description: String {
        switch self {
        case let .io(path, reason):
            return "Failed to read manifest file '\(path)': \(reason)"
        case let .parse(message):
            return "Failed to parse TOML manifest: \(message)"
        case let .serialize(message):
            return "Failed to serialize manifest to TOML: \(message)"
        case let .validation(count, message):
            return "Manifest validation failed with \(count) errors: \(message)"
        case let .unknownProfile(name):
            return "Unknown profile '\(name)'"
        case let .profileCycle(cycle):
            return "Profile cycle detected: \(cycle)"
        }
    }

    public var errorDescription: String? { description }
}

/// One problem found by ``validateManifest(_:)``.
public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case unsupportedSchemaVersion(version: UInt32, expected: UInt32)
    case emptySourcePath(target: String)
    case absoluteSourcePath(sourcePath: String)
    case emptyTargetPath(sourcePath: String)
    case duplicateTargetPath(target: String)
    case illegalPathTraversal(sourcePath: String)
    case sensitiveCredentialPath(path: String)
    case invalidExclusionPattern(pattern: String, reason: String)
    case unknownProfile(name: String, context: String)
    case profileCycle(cycle: String)
    case invalidOsCondition(value: String)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(version, expected):
            return "Unsupported schema version \(version); expected \(expected)"
        case let .emptySourcePath(target):
            return "Empty source path for tracked file targeting '\(target)'"
        case let .absoluteSourcePath(sourcePath):
            return "Source path '\(sourcePath)' must be a relative path within repository root"
        case let .emptyTargetPath(sourcePath):
            return "Empty target path for tracked file with source '\(sourcePath)'"
        case let .duplicateTargetPath(target):
            return "Duplicate target path '\(target)'"
        case let .illegalPathTraversal(sourcePath):
            return "Source path '\(sourcePath)' contains illegal directory traversal ('..')"
        case let .sensitiveCredentialPath(path):
            return "Dangerous or sensitive credential path tracked: '\(path)'"
        case let .invalidExclusionPattern(pattern, reason):
            return "Invalid exclusion pattern '\(pattern)': \(reason)"
        case let .unknownProfile(name, context):
            return "Unknown profile '\(name)' referenced from \(context)"
        case let .profileCycle(cycle):
            return "Profile cycle detected: \(cycle)"
        case let .invalidOsCondition(value):
            return "Invalid OS condition '\(value)'"
        }
    }

    public var errorDescription: String? { description }
}
