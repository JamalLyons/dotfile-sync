// Port of crates/dotfilesync-daemon/src/fsutil.rs: owner-only files, time and randomness.

import Darwin
import Foundation
import System

/// Current Unix time in milliseconds.
public func nowMs() -> UInt64 {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return UInt64(max(0, tv.tv_sec)) * 1000 + UInt64(max(0, tv.tv_usec)) / 1000
}

/// An I/O failure carrying a Rust-style message.
public struct AgentIOError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    /// `errno`, when the failure came from a syscall.
    public var code: Int32?

    public init(_ message: String, code: Int32? = nil) {
        self.message = message
        self.code = code
    }

    static func errno(_ code: Int32) -> AgentIOError {
        AgentIOError("\(String(cString: strerror(code))) (os error \(code))", code: code)
    }

    public var description: String { message }
}

/// `n` random bytes from the kernel CSPRNG (`arc4random_buf`), lowercase hex-encoded.
public func randomHex(_ n: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: n)
    bytes.withUnsafeMutableBytes { buf in
        if let base = buf.baseAddress {
            arc4random_buf(base, buf.count)
        }
    }
    return hexString(bytes)
}

/// Lowercase hex (Rust `hex::encode`).
func hexString(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}

/// How ``openPrivateFile(_:mode:)`` opens an existing file.
public enum OpenMode: Sendable {
    case append
    case truncate
}

/// An owned file descriptor, closed on deinit. Not shared across threads without a lock.
public final class PrivateFile {
    public let fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// Writes every byte (retrying on short writes and `EINTR`).
    public func writeAll(_ bytes: [UInt8]) throws(AgentIOError) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return write(fd, base + offset, bytes.count - offset)
            }
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                throw .errno(code)
            }
            offset += n
        }
    }

    /// `fsync`.
    public func sync() throws(AgentIOError) {
        if fsync(fd) != 0 {
            throw .errno(errno)
        }
    }

    /// Current size in bytes.
    public func size() throws(AgentIOError) -> UInt64 {
        var st = stat()
        if fstat(fd, &st) != 0 {
            throw .errno(errno)
        }
        return UInt64(max(0, st.st_size))
    }

    /// Reads to end of file.
    public func readAll() throws(AgentIOError) -> [UInt8] {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return 0 }
                return read(fd, base, buf.count)
            }
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                throw .errno(code)
            }
            if n == 0 { break }
            out.append(contentsOf: chunk[0..<n])
        }
        return out
    }
}

/// Opens (creating with 0600 if needed) a file that must be private to the current user.
/// Symlinks are refused (`O_NOFOLLOW`), and an existing file not owned by us or readable by
/// group/other is rejected rather than silently fixed.
public func openPrivateFile(_ path: FilePath, mode: OpenMode) throws(AgentIOError) -> PrivateFile {
    var flags = O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_WRONLY
    switch mode {
    case .append: flags |= O_APPEND
    case .truncate: flags |= O_TRUNC
    }
    let fd = path.withPlatformString { open($0, flags, mode_t(0o600)) }
    if fd < 0 {
        throw .errno(errno)
    }
    let file = PrivateFile(fd: fd)
    try verifyPrivate(file, path)
    return file
}

/// Opens an existing private file for reading (`O_NOFOLLOW`, owner-only check).
public func openPrivateRead(_ path: FilePath) throws(AgentIOError) -> PrivateFile {
    let fd = path.withPlatformString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    if fd < 0 {
        throw .errno(errno)
    }
    let file = PrivateFile(fd: fd)
    try verifyPrivate(file, path)
    return file
}

private func verifyPrivate(_ file: PrivateFile, _ path: FilePath) throws(AgentIOError) {
    var st = stat()
    if fstat(file.fd, &st) != 0 {
        throw .errno(errno)
    }
    if st.st_mode & S_IFMT != S_IFREG {
        throw AgentIOError("'\(path.string)' is not a regular file")
    }
    if st.st_uid != geteuid() {
        throw AgentIOError("'\(path.string)' is owned by uid \(st.st_uid)", code: EACCES)
    }
    let mode = UInt32(st.st_mode) & 0o7777
    if mode & 0o077 != 0 {
        let s = String(mode, radix: 8)
        let padded = String(repeating: "0", count: max(0, 4 - s.count)) + s
        throw AgentIOError("'\(path.string)' has mode \(padded); expected owner-only (0600)", code: EACCES)
    }
}

/// Reads a whole file (following symlinks, no privacy checks), or `nil` if unreadable.
func readFileBytes(_ path: FilePath) -> [UInt8]? {
    let fd = path.withPlatformString { open($0, O_RDONLY | O_CLOEXEC) }
    if fd < 0 {
        return nil
    }
    let file = PrivateFile(fd: fd)
    return try? file.readAll()
}

/// `lstat`-based helpers.
func isDirectory(_ path: FilePath) -> Bool {
    var st = stat()
    return path.withPlatformString { stat($0, &st) } == 0 && st.st_mode & S_IFMT == S_IFDIR
}

func isRegularFile(_ path: FilePath) -> Bool {
    var st = stat()
    return path.withPlatformString { stat($0, &st) } == 0 && st.st_mode & S_IFMT == S_IFREG
}

func pathExists(_ path: FilePath) -> Bool {
    var st = stat()
    return path.withPlatformString { lstat($0, &st) } == 0
}

func removeFile(_ path: FilePath) {
    _ = path.withPlatformString { unlink($0) }
}

func renamePath(_ from: FilePath, _ to: FilePath) throws(AgentIOError) {
    let rc = from.withPlatformString { f in to.withPlatformString { t in rename(f, t) } }
    if rc != 0 {
        throw .errno(errno)
    }
}

/// Entries of a directory (excluding `.` and `..`), or an error.
func listDirectory(_ path: FilePath) throws(AgentIOError) -> [FilePath] {
    guard let dir = path.withPlatformString({ opendir($0) }) else {
        throw .errno(errno)
    }
    defer { closedir(dir) }
    var out: [FilePath] = []
    while let entry = readdir(dir) {
        let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        out.append(path.appending(name))
    }
    return out
}
