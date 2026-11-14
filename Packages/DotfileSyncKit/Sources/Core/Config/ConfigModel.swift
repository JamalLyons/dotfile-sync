// Port of crates/dotfilesync-core/src/config/model.rs.

import System

/// Observed state of one tracked configuration file. Encodes as a snake_case string.
public enum ConfigFileState: String, Codable, Sendable, Hashable {
    case matching
    case changed
    case missing
    case machineLocal = "machine_local"
    case excluded
    case symlinkToSource = "symlink_to_source"
    case symlinkExternal = "symlink_external"
    case brokenSymlink = "broken_symlink"
    case sourceMissing = "source_missing"
    case sourceOutsideRoot = "source_outside_root"
    case unreadable
}

/// Result of inspecting one tracked file on the machine.
///
/// JSON keys are snake_case in declaration order; optional fields are omitted when nil. Paths
/// encode as strings (non-UTF-8 bytes become U+FFFD, where Rust serde would fail instead).
public struct ObservedConfigFile: Codable, Sendable, Equatable {
    public var sourcePath: FilePath
    public var targetPath: FilePath
    public var state: ConfigFileState
    /// Hex SHA-256 of the repository source.
    public var sourceHash: String?
    /// Hex SHA-256 of the machine target.
    public var targetHash: String?
    /// Size in bytes of a regular target file (`lstat` length).
    public var targetSize: UInt64?
    public var isSymlink: Bool
    /// Raw `readlink` destination of a symlinked target.
    public var symlinkTarget: FilePath?
    public var diagnostic: String?

    public init(
        sourcePath: FilePath,
        targetPath: FilePath,
        state: ConfigFileState,
        sourceHash: String? = nil,
        targetHash: String? = nil,
        targetSize: UInt64? = nil,
        isSymlink: Bool = false,
        symlinkTarget: FilePath? = nil,
        diagnostic: String? = nil
    ) {
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.state = state
        self.sourceHash = sourceHash
        self.targetHash = targetHash
        self.targetSize = targetSize
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.diagnostic = diagnostic
    }

    private enum CodingKeys: String, CodingKey {
        case sourcePath = "source_path"
        case targetPath = "target_path"
        case state
        case sourceHash = "source_hash"
        case targetHash = "target_hash"
        case targetSize = "target_size"
        case isSymlink = "is_symlink"
        case symlinkTarget = "symlink_target"
        case diagnostic
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourcePath = FilePath(try c.decode(String.self, forKey: .sourcePath))
        targetPath = FilePath(try c.decode(String.self, forKey: .targetPath))
        state = try c.decode(ConfigFileState.self, forKey: .state)
        sourceHash = try c.decodeIfPresent(String.self, forKey: .sourceHash)
        targetHash = try c.decodeIfPresent(String.self, forKey: .targetHash)
        targetSize = try c.decodeIfPresent(UInt64.self, forKey: .targetSize)
        isSymlink = try c.decode(Bool.self, forKey: .isSymlink)
        symlinkTarget = try c.decodeIfPresent(String.self, forKey: .symlinkTarget).map { FilePath($0) }
        diagnostic = try c.decodeIfPresent(String.self, forKey: .diagnostic)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourcePath.string, forKey: .sourcePath)
        try c.encode(targetPath.string, forKey: .targetPath)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(sourceHash, forKey: .sourceHash)
        try c.encodeIfPresent(targetHash, forKey: .targetHash)
        try c.encodeIfPresent(targetSize, forKey: .targetSize)
        try c.encode(isSymlink, forKey: .isSymlink)
        try c.encodeIfPresent(symlinkTarget?.string, forKey: .symlinkTarget)
        try c.encodeIfPresent(diagnostic, forKey: .diagnostic)
    }
}
