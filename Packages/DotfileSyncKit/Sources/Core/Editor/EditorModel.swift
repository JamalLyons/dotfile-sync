import System

/// The on-disk version of a file. All three fields participate in conflict detection.
public struct FileVersion: Codable, Sendable, Equatable {
    /// Modification time in nanoseconds since the Unix epoch.
    public let mtimeNs: Int64
    /// File size in bytes.
    public let size: Int
    /// Lowercase hex SHA-256 of the file contents.
    public let sha256: String

    /// Reconstructs a version received from a caller.
    public init(mtimeNs: Int64, size: Int, sha256: String) {
        self.mtimeNs = mtimeNs
        self.size = size
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case mtimeNs = "mtime_ns"
        case size, sha256
    }
}

/// A snapshot of a regular file, with binary content available for viewing only.
public struct EditorDocument: Sendable, Equatable {
    /// The requested file path.
    public let path: FilePath
    /// The exact on-disk bytes.
    public let bytes: [UInt8]
    /// The decoded text, or nil if the file contains NUL or malformed UTF-8.
    public let text: String?
    /// Whether the file is view-only.
    public var isBinary: Bool { text == nil }
    /// The size of the snapshot in bytes.
    public var sizeBytes: Int { version.size }
    /// POSIX permission bits.
    public let mode: UInt32
    /// The version to supply when saving changes.
    public let version: FileVersion
}

/// The outcome of a successful save, create, or rename.
public struct EditorWriteReport: Sendable, Equatable {
    /// The path written to, or the destination of a rename.
    public let path: FilePath
    /// The saved copy of the previous contents, when the operation replaced a file.
    public let backupPath: FilePath?
    /// The version at the destination after the operation.
    public let newVersion: FileVersion
}

/// A config editor operation failure.
public enum EditorError: Error, Codable, Sendable, Equatable {
    /// The path is relative, outside the configured roots, or a rename crosses roots.
    case outsideRoots
    /// The path contains a parent traversal component or an embedded NUL.
    case pathTraversal
    /// A path component within a configured root is a symlink.
    case symlinkEscape
    /// A file is not regular or an ancestor is not a directory.
    case notRegularFile
    /// The input or on-disk file exceeds the byte limit.
    case tooLarge(limit: Int, size: Int)
    /// The input or on-disk file contains NUL or malformed UTF-8.
    case binaryFile
    /// The file on disk has changed since the supplied version.
    case conflict(current: FileVersion)
    /// The destination already exists.
    case alreadyExists
    /// The file or one of its ancestors does not exist.
    case notFound
    /// Another filesystem or configuration error.
    case io(message: String)
}
