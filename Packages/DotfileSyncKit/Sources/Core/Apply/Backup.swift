// Port of crates/dotfilesync-core/src/apply/backup.rs (`backup_existing`, `move_file`,
// `relative_to_home`, `format_stamp`).
//
// Native change: the backup is first attempted with APFS `clonefile(2)` (`CLONE_NOFOLLOW`,
// copy-on-write, preserves mode and ownership) followed by removing the original. If cloning
// fails for any reason (`ENOTSUP` on non-APFS, `EXDEV` across volumes, `EEXIST` on a name
// collision, ...), the Rust move runs unchanged: `rename(2)`, and on `EXDEV` a byte copy plus
// remove. Naming, collision handling (rename replaces an existing destination), error messages
// and the journaled path are identical to Rust, since every error comes from the Rust path.

import Darwin
import System

/// How ``backupExisting(home:backupRoot:runId:target:nowMs:)`` moved the file into place.
public enum BackupStrategy: String, Sendable, Equatable {
    /// `clonefile(2)` made a copy-on-write clone, then the original was removed.
    case cloned
    /// Cloning failed; `rename(2)` moved the original (the Rust fast path).
    case renamed
    /// Cloning failed and `rename` failed with `EXDEV`; bytes and mode were copied.
    case copied
}

/// Filesystem primitives used by the backup move, injectable for tests.
///
/// Each returns `0` on success or the `errno` value on failure.
struct BackupFileOps: Sendable {
    var clone: @Sendable (FilePath, FilePath) -> Int32
    var rename: @Sendable (FilePath, FilePath) -> Int32

    static let system = BackupFileOps(
        clone: { from, to in
            from.withPlatformString { src in
                to.withPlatformString { dst in clonefile(src, dst, UInt32(CLONE_NOFOLLOW)) }
            } == 0 ? 0 : errno
        },
        rename: { from, to in renamePath(from, to) == 0 ? 0 : errno }
    )
}

/// Moves `target` into `<backupRoot>/<runId>/<path-relative-to-home>.backup.YYYYmmdd_HHMMSS`
/// and returns the backup path.
public func backupExisting(
    home: FilePath,
    backupRoot: FilePath,
    runId: String,
    target: FilePath,
    nowMs: UInt64
) throws(ApplyIOError) -> FilePath {
    try backupExisting(
        home: home, backupRoot: backupRoot, runId: runId, target: target, nowMs: nowMs, ops: .system
    ).path
}

func backupExisting(
    home: FilePath,
    backupRoot: FilePath,
    runId: String,
    target: FilePath,
    nowMs: UInt64,
    ops: BackupFileOps
) throws(ApplyIOError) -> (path: FilePath, strategy: BackupStrategy) {
    let relative = relativeToHome(home: home, target: target)
    let fileName = rustFileName(relative).map { String(decoding: $0, as: UTF8.self) } ?? "file"
    let stamped = "\(fileName).backup.\(formatStamp(nowMs))"
    let parent = rustParent(relative) ?? FilePath("")
    let dest = backupRoot.pushing(FilePath(runId)).pushing(parent).pushing(FilePath(stamped))
    if let destParent = rustParent(dest) {
        try ensureDir(destParent)
    }
    let strategy = try moveFile(target, dest, ops: ops)
    return (dest, strategy)
}

private func moveFile(_ source: FilePath, _ dest: FilePath, ops: BackupFileOps) throws(ApplyIOError) -> BackupStrategy {
    // Only files and symlinks are cloned: `clonefile` would clone a whole directory tree,
    // which `rename` moves in one step instead.
    if isFileOrSymlink(source), ops.clone(source, dest) == 0 {
        if source.withPlatformString({ unlink($0) }) == 0 {
            return .cloned
        }
        // The original could not be removed: drop the clone and let the Rust
        // path below handle (and report) it.
        _ = dest.withPlatformString { unlink($0) }
    }
    let renameError = ops.rename(source, dest)
    if renameError == 0 {
        return .renamed
    }
    guard renameError == EXDEV else {
        throw ApplyIOError(
            "failed to back up '\(source.string)' to '\(dest.string)': \(OSIOError(errno: renameError))"
        )
    }
    do {
        try copyFileContents(source, dest)
    } catch {
        throw ApplyIOError("failed to copy '\(source.string)' to '\(dest.string)': \(error)")
    }
    if source.withPlatformString({ unlink($0) }) != 0 {
        throw ApplyIOError(
            "failed to remove '\(source.string)' after backup: \(OSIOError.current())"
        )
    }
    return .copied
}

private func isFileOrSymlink(_ path: FilePath) -> Bool {
    guard case let .success(st) = lstatPath(path) else { return false }
    let kind = st.st_mode & S_IFMT
    return kind == S_IFREG || kind == S_IFLNK
}

/// Rust `fs::copy` (data plus permission bits, following symlinks; truncates `dest`).
private func copyFileContents(_ source: FilePath, _ dest: FilePath) throws(OSIOError) {
    let input = source.withPlatformString { open($0, O_RDONLY | O_CLOEXEC) }
    if input < 0 {
        throw OSIOError.current()
    }
    defer { close(input) }
    var st = stat()
    if fstat(input, &st) != 0 {
        throw OSIOError.current()
    }
    if (st.st_mode & S_IFMT) != S_IFREG {
        // Rust: "the source path is neither a regular file nor a symlink to a regular file".
        throw OSIOError(errno: EINVAL)
    }
    let mode = st.st_mode & 0o7777
    let output = dest.withPlatformString { open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode) }
    if output < 0 {
        throw OSIOError.current()
    }
    defer { close(output) }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            throw OSIOError.current()
        }
        if count == 0 { break }
        if let error = writeAll(output, Array(buffer[0..<count])) {
            throw error
        }
    }
    if fchmod(output, mode) != 0 {
        throw OSIOError.current()
    }
}

/// Rust `relative_to_home`: `target.strip_prefix(home)`, else the target's normal components.
func relativeToHome(home: FilePath, target: FilePath) -> FilePath {
    let targetComponents = rustComponents(target)
    let homeComponents = rustComponents(home)
    let remainder: ArraySlice<RustPathComponent>
    if targetComponents.count >= homeComponents.count,
       Array(targetComponents.prefix(homeComponents.count)) == homeComponents
    {
        remainder = targetComponents.dropFirst(homeComponents.count)
    } else {
        remainder = ArraySlice(targetComponents.filter {
            if case .normal = $0 { return true }
            return false
        })
    }
    var bytes: [UInt8] = []
    for component in remainder {
        if !bytes.isEmpty { bytes.append(UInt8(ascii: "/")) }
        switch component {
        case .rootDir: bytes = [UInt8(ascii: "/")]
        case .curDir: bytes.append(UInt8(ascii: "."))
        case .parentDir: bytes.append(contentsOf: Array("..".utf8))
        case let .normal(name): bytes.append(contentsOf: name)
        }
    }
    return filePath(fromBytes: bytes)
}

/// UTC `YYYYmmdd_HHMMSS` for a Unix timestamp in milliseconds.
func formatStamp(_ ms: UInt64) -> String {
    let secs = Int64(ms / 1000)
    let days = secs >= 0 ? secs / 86_400 : (secs - 86_399) / 86_400
    let tod = secs - days * 86_400
    let hour = tod / 3600
    let minute = (tod % 3600) / 60
    let second = tod % 60
    let (year, month, day) = civilFromDays(days)
    return pad(year, 4) + pad(Int64(month), 2) + pad(Int64(day), 2) + "_"
        + pad(hour, 2) + pad(minute, 2) + pad(second, 2)
}

private func pad(_ value: Int64, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

/// Howard Hinnant's `civil_from_days`, days counted from the Unix epoch.
func civilFromDays(_ unixDays: Int64) -> (Int64, UInt32, UInt32) {
    let z = unixDays + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = UInt64(z - era * 146_097)
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let y = Int64(yoe) + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = UInt32(doy - (153 * mp + 2) / 5 + 1)
    let month = UInt32(mp < 10 ? mp + 3 : mp - 9)
    let year = month <= 2 ? y + 1 : y
    return (year, month, day)
}
