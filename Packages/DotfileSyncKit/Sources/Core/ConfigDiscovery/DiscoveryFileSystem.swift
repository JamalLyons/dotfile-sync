// The filesystem seam for config discovery. It exposes metadata operations only: there is no
// way to open or read a file through it, so discovery cannot read contents by construction.

import Darwin
import System

/// `lstat` facts discovery needs about one path.
public struct DiscoveryMetadata: Sendable, Equatable {
    public var kind: DiscoveredEntryKind
    /// `st_size`; meaningful for regular files.
    public var size: UInt64

    public init(kind: DiscoveredEntryKind, size: UInt64) {
        self.kind = kind
        self.size = size
    }
}

/// Metadata-only filesystem access used by ``discoverConfigs(home:environment:limits:registry:fileSystem:)``.
///
/// Implementations must not follow symlinks in ``metadata(_:)`` and must not read file contents.
public protocol DiscoveryFileSystem {
    /// `lstat(path)`; `nil` when the path does not exist or cannot be stat'ed.
    func metadata(_ path: FilePath) -> DiscoveryMetadata?
    /// Names in directory `path` (excluding `.` and `..`), in any order.
    func listDirectory(_ path: FilePath) throws(OSIOError) -> [String]
    /// `readlink(path)`: the raw destination of a symlink, without following it.
    func symlinkDestination(_ path: FilePath) -> FilePath?
}

/// ``DiscoveryFileSystem`` backed by Darwin `lstat`, `opendir`/`readdir`, and `readlink`.
public struct DarwinDiscoveryFileSystem: DiscoveryFileSystem, Sendable {
    public init() {}

    public func metadata(_ path: FilePath) -> DiscoveryMetadata? {
        guard case let .success(st) = lstatPath(path) else { return nil }
        let kind: DiscoveredEntryKind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return DiscoveryMetadata(kind: kind, size: UInt64(max(st.st_size, 0)))
    }

    public func listDirectory(_ path: FilePath) throws(OSIOError) -> [String] {
        guard let dir = path.withPlatformString({ opendir($0) }) else {
            throw OSIOError.current()
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    public func symlinkDestination(_ path: FilePath) -> FilePath? {
        try? readLink(path)
    }
}
