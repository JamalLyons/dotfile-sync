// The filesystem seam for config discovery. It exposes metadata and directory-listing operations
// only: there is no way to open or read a file through it, so discovery cannot read contents by
// construction.

import Darwin
import System

/// `lstat` facts discovery needs about one path.
public struct DiscoveryMetadata: Sendable, Equatable {
    public var kind: DiscoveredEntryKind
    /// `st_size`; meaningful for regular files.
    public var size: UInt64
    /// `st_dev` and `st_ino`: the identity a later open must match before a directory is listed.
    public var device: dev_t
    public var inode: ino_t

    public init(kind: DiscoveredEntryKind, size: UInt64, device: dev_t = 0, inode: ino_t = 0) {
        self.kind = kind
        self.size = size
        self.device = device
        self.inode = inode
    }
}

/// The names read from one directory, capped at the limit the caller asked for.
public struct DirectoryListing: Sendable, Equatable {
    /// Names in directory order (excluding `.` and `..`), at most the requested limit.
    public var names: [String]
    /// `true` when the directory held more names than were returned.
    public var truncated: Bool

    public init(names: [String], truncated: Bool) {
        self.names = names
        self.truncated = truncated
    }
}

/// Metadata-only filesystem access used by ``discoverConfigs(home:environment:limits:registry:fileSystem:)``.
///
/// Implementations must not follow symlinks in ``metadata(_:)`` and must not read file contents.
public protocol DiscoveryFileSystem {
    /// `lstat(path)`; `nil` when the path does not exist or cannot be stat'ed.
    func metadata(_ path: FilePath) -> DiscoveryMetadata?
    /// Lists directory `path`, reading at most `limit` names.
    ///
    /// The directory must be opened without following a symlink at `path`, and the opened
    /// directory's device and inode must equal `identity` (the ``metadata(_:)`` result for `path`).
    /// Otherwise the call throws, so a path swapped after its `lstat` is never listed.
    func listDirectory(
        _ path: FilePath, expecting identity: DiscoveryMetadata, limit: Int
    ) throws(OSIOError) -> DirectoryListing
    /// `readlink(path)`: the raw destination of a symlink, without following it.
    func symlinkDestination(_ path: FilePath) -> FilePath?
}

/// ``DiscoveryFileSystem`` backed by Darwin `lstat`, `open`/`fdopendir`/`readdir`, and `readlink`.
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
        return DiscoveryMetadata(
            kind: kind, size: UInt64(max(st.st_size, 0)), device: st.st_dev, inode: st.st_ino)
    }

    /// Opens with `O_NOFOLLOW | O_DIRECTORY`, so a symlink or non-directory at `path` fails at open
    /// time instead of being resolved. `fstat` then checks the opened inode against `identity`, which
    /// also catches a directory swapped for a different one or an ancestor swapped for a symlink.
    /// `readdir` runs on that same descriptor and stops after `limit` names.
    public func listDirectory(
        _ path: FilePath, expecting identity: DiscoveryMetadata, limit: Int
    ) throws(OSIOError) -> DirectoryListing {
        let fd = path.withPlatformString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw OSIOError.current() }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let error = OSIOError.current()
            close(fd)
            throw error
        }
        guard st.st_dev == identity.device, st.st_ino == identity.inode else {
            close(fd)
            throw OSIOError(errno: ESTALE)
        }
        // `fdopendir` takes ownership of `fd` on success; `closedir` then closes it.
        guard let dir = fdopendir(fd) else {
            let error = OSIOError.current()
            close(fd)
            throw error
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
            // One real name beyond the limit proves truncation; stop reading there.
            if names.count == limit {
                return DirectoryListing(names: names, truncated: true)
            }
            names.append(name)
        }
        return DirectoryListing(names: names, truncated: false)
    }

    public func symlinkDestination(_ path: FilePath) -> FilePath? {
        try? readLink(path)
    }
}
