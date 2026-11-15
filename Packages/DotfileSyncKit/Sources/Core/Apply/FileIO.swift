// Port of crates/dotfilesync-core/src/apply/backup.rs (`ensure_dir`, `write_atomic`) and
// `apply::sync_file`, plus the POSIX helpers apply needs.
//
// POSIX calls keep Rust std semantics: `DirBuilder::mode(0o755)` = mkdir(0755), `OpenOptions`
// create/write/truncate = open(O_WRONLY|O_CREAT|O_TRUNC, 0666), `File::sync_all` on Apple
// platforms = fcntl(F_FULLFSYNC), `fs::set_permissions` = chmod, `fs::rename` = rename(2).

import Darwin
import System

/// Creates `path` and any missing parents with mode `0755` (subject to the umask).
///
/// A path that already exists (as anything, per `lstat`) is accepted unchanged.
public func ensureDir(_ path: FilePath) throws(ApplyIOError) {
    if path.isEmpty || pathPresent(path) {
        return
    }
    if let parent = rustParent(path), !parent.isEmpty {
        try ensureDir(parent)
    }
    if path.withPlatformString({ mkdir($0, 0o755) }) != 0 {
        throw ApplyIOError("failed to create directory '\(path.string)': \(OSIOError.current())")
    }
}

/// Writes `bytes` to `<target>.tmp` next to `target`, fsyncs it, sets `mode`, then renames it
/// over `target`. Missing parent directories are created with mode `0755`.
public func writeAtomic(_ target: FilePath, bytes: [UInt8], mode: UInt32) throws(ApplyIOError) {
    let parent = rustParent(target).flatMap { $0.isEmpty ? nil : $0 }
    if let parent {
        try ensureDir(parent)
    }
    var tmpName = rustFileName(target) ?? Array("file".utf8)
    tmpName.append(contentsOf: Array(".tmp".utf8))
    let tmpComponent = filePath(fromBytes: tmpName)
    let tmp = parent.map { $0.pushing(tmpComponent) } ?? tmpComponent

    let fd = tmp.withPlatformString { open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666) }
    if fd < 0 {
        throw ApplyIOError("failed to open temp file '\(tmp.string)': \(OSIOError.current())")
    }
    do {
        defer { close(fd) }
        if let error = writeAll(fd, bytes) {
            throw ApplyIOError("failed to write '\(tmp.string)': \(error)")
        }
        if let error = fullFsync(fd) {
            throw ApplyIOError("failed to fsync '\(tmp.string)': \(error)")
        }
        if tmp.withPlatformString({ chmod($0, mode_t(mode)) }) != 0 {
            throw ApplyIOError("failed to set mode on '\(tmp.string)': \(OSIOError.current())")
        }
    }
    if renamePath(tmp, target) != 0 {
        throw ApplyIOError(
            "failed to rename '\(tmp.string)' to '\(target.string)': \(OSIOError.current())"
        )
    }
}

/// Writes `bytes` to `path` (create/truncate, mode `0666` before umask) and fsyncs it.
/// Parent directories are created with mode `0755`.
public func syncFile(_ path: FilePath, bytes: [UInt8]) throws(ApplyIOError) {
    if let parent = rustParent(path) {
        try ensureDir(parent)
    }
    let fd = path.withPlatformString { open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666) }
    if fd < 0 {
        throw ApplyIOError("failed to open '\(path.string)': \(OSIOError.current())")
    }
    defer { close(fd) }
    if let error = writeAll(fd, bytes) {
        throw ApplyIOError("failed to write '\(path.string)': \(error)")
    }
    if let error = fullFsync(fd) {
        throw ApplyIOError("failed to fsync '\(path.string)': \(error)")
    }
}

/// A filesystem failure from the apply layer, carrying the Rust-identical message.
public struct ApplyIOError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

// MARK: - POSIX helpers

/// Rust `fs::symlink_metadata(path).is_ok()`.
func pathPresent(_ path: FilePath) -> Bool {
    if case .success = lstatPath(path) {
        return true
    }
    return false
}

/// Rust `fs::read`.
func readAllBytes(_ path: FilePath) throws(OSIOError) -> [UInt8] {
    let fd = path.withPlatformString { open($0, O_RDONLY | O_CLOEXEC) }
    if fd < 0 {
        throw OSIOError.current()
    }
    defer { close(fd) }
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            throw OSIOError.current()
        }
        if count == 0 { break }
        result.append(contentsOf: buffer[0..<count])
    }
    return result
}

/// Rust `Write::write_all`; returns the error, or `nil` on success.
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> OSIOError? {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return write(fd, base + offset, raw.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            return OSIOError.current()
        }
        if written == 0 {
            // Rust maps a zero-length write to `ErrorKind::WriteZero`.
            return OSIOError(errno: EIO)
        }
        offset += written
    }
    return nil
}

/// Rust `File::sync_all` on Apple platforms: `fcntl(F_FULLFSYNC)`, retried on `EINTR`.
func fullFsync(_ fd: Int32) -> OSIOError? {
    while true {
        if fcntl(fd, F_FULLFSYNC) == 0 {
            return nil
        }
        if errno != EINTR {
            return OSIOError.current()
        }
    }
}

func renamePath(_ from: FilePath, _ to: FilePath) -> Int32 {
    from.withPlatformString { src in to.withPlatformString { dst in rename(src, dst) } }
}

/// `stat` (follows symlinks) permission bits, Rust `metadata().permissions().mode() & 0o777`.
func fileMode(_ path: FilePath) -> UInt32? {
    var st = stat()
    guard path.withPlatformString({ stat($0, &st) }) == 0 else { return nil }
    return UInt32(st.st_mode) & 0o777
}
