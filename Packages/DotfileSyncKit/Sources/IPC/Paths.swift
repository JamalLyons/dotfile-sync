// Port of crates/dotfilesync-protocol/src/paths.rs: the per-user data directory layout and
// owner-only directory checks. The socket path, lock file and socket-length check are not
// ported (XPC + SMAppService replace the socket and single-instance lock).

import Darwin
import Foundation
import System

/// Environment variable that relocates the whole data directory (tests and power users).
public let DATA_DIR_ENV = "DOTFILESYNC_DATA_DIR"

/// Why a private directory cannot be used. `description` matches the Rust `Display` text.
public enum PathError: Error, Sendable, Equatable, CustomStringConvertible {
    case noHome
    case symlink(path: FilePath)
    case notADirectory(path: FilePath)
    case wrongOwner(path: FilePath, owner: UInt32, expected: UInt32)
    case tooPermissive(path: FilePath, mode: UInt32)
    case io(path: FilePath, message: String)

    public var description: String {
        switch self {
        case .noHome:
            return "cannot determine the data directory: HOME is not set; pass --data-dir or set \(DATA_DIR_ENV)"
        case let .symlink(path):
            return "'\(path.string)' is a symlink; refusing to use it as a private dotfilesync directory"
        case let .notADirectory(path):
            return "'\(path.string)' exists but is not a directory"
        case let .wrongOwner(path, owner, expected):
            return "'\(path.string)' is owned by uid \(owner), not the current user (uid \(expected)); refusing to use it"
        case let .tooPermissive(path, mode):
            return "'\(path.string)' has mode \(octal4(mode)), which allows access by other users; run `chmod 700 '\(path.string)'` and retry"
        case let .io(path, message):
            return "i/o error on '\(path.string)': \(message)"
        }
    }
}

/// `{:04o}` formatting.
func octal4(_ mode: UInt32) -> String {
    let s = String(mode, radix: 8)
    return s.count >= 4 ? s : String(repeating: "0", count: 4 - s.count) + s
}

/// The `strerror` text of `errno`, like Rust's `io::Error` display.
func errnoMessage(_ code: Int32) -> String {
    "\(String(cString: strerror(code))) (os error \(code))"
}

/// All agent paths derived from one root.
public struct DataLayout: Sendable, Equatable {
    public var root: FilePath
    public var stateDir: FilePath
    /// `<state>/jobs.jsonl`.
    public var journal: FilePath
    /// `<state>/runs/<run_id>/` holds `journal.jsonl`, `plan.json`, and `meta.json`.
    public var runsDir: FilePath
    /// `<root>/backups/<run_id>/` holds files replaced by apply.
    public var backupsDir: FilePath
    public var logsDir: FilePath
    /// `<logs>/dotfilesyncd.log` (name kept from the Rust daemon so state stays compatible).
    public var logFile: FilePath

    /// Derives every path from `root`.
    public init(root: FilePath) {
        self.root = root
        stateDir = root.appending("state")
        logsDir = root.appending("logs")
        journal = stateDir.appending("jobs.jsonl")
        runsDir = stateDir.appending("runs")
        backupsDir = root.appending("backups")
        logFile = logsDir.appending("dotfilesyncd.log")
    }

    /// Resolves the data directory: explicit override, then `$DOTFILESYNC_DATA_DIR`, then
    /// `$HOME/Library/Application Support/dotfilesync`. Relative paths become absolute against
    /// the current directory.
    public static func resolve(
        explicit: FilePath? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(PathError) -> DataLayout {
        var root: FilePath
        if let explicit {
            root = explicit
        } else if let env = environment[DATA_DIR_ENV], !env.isEmpty {
            root = FilePath(env)
        } else {
            guard let home = environment["HOME"], !home.isEmpty else {
                throw .noHome
            }
            root = FilePath(home).appending("Library/Application Support/dotfilesync")
        }
        if !root.isAbsolute {
            root = FilePath(FileManager.default.currentDirectoryPath).pushing(root)
        }
        return DataLayout(root: root)
    }

    /// The private directories, in creation order.
    public var privateDirs: [FilePath] {
        [root, stateDir, runsDir, backupsDir, logsDir]
    }

    /// Creates (if needed) and validates every private directory. Agent-side only.
    public func ensurePrivateDirs() throws(PathError) {
        for dir in privateDirs {
            try ensurePrivateDir(dir)
        }
    }
}

/// Outcome of a non-creating check.
public enum DirState: Sendable, Equatable {
    case missing
    case `private`
}

/// Verifies (without creating or modifying) that `path` is a real directory owned by the
/// effective UID with no group/other permission bits. Symlinks are never followed.
public func checkPrivateDir(_ path: FilePath) throws(PathError) -> DirState {
    var st = stat()
    let rc = path.withPlatformString { lstat($0, &st) }
    if rc != 0 {
        let code = errno
        if code == ENOENT {
            return .missing
        }
        throw .io(path: path, message: errnoMessage(code))
    }
    let type = st.st_mode & S_IFMT
    if type == S_IFLNK {
        throw .symlink(path: path)
    }
    if type != S_IFDIR {
        throw .notADirectory(path: path)
    }
    let expected = geteuid()
    if st.st_uid != expected {
        throw .wrongOwner(path: path, owner: st.st_uid, expected: expected)
    }
    let mode = UInt32(st.st_mode) & 0o7777
    if mode & 0o077 != 0 {
        throw .tooPermissive(path: path, mode: mode)
    }
    return .private
}

/// Creates `path` with mode 0700 if missing (parents too), then validates it. Never relaxes or
/// silently repairs the permissions of an existing directory.
public func ensurePrivateDir(_ path: FilePath) throws(PathError) {
    if try checkPrivateDir(path) == .missing {
        try createDirAll(path, mode: 0o700)
        // mkdir's mode is subject to umask, which can only remove bits; re-check below.
    }
    switch try checkPrivateDir(path) {
    case .private:
        return
    case .missing:
        throw .io(path: path, message: "directory vanished after creation")
    }
}

/// `DirBuilder::new().recursive(true).mode(mode)`: missing ancestors are created with `mode`.
private func createDirAll(_ path: FilePath, mode: mode_t) throws(PathError) {
    var st = stat()
    if path.withPlatformString({ stat($0, &st) }) == 0 {
        return
    }
    if let parent = parentPath(path) {
        try createDirAll(parent, mode: mode)
    }
    if path.withPlatformString({ mkdir($0, mode) }) != 0 {
        let code = errno
        if code == EEXIST {
            return
        }
        throw .io(path: path, message: errnoMessage(code))
    }
}

private func parentPath(_ path: FilePath) -> FilePath? {
    let parent = path.removingLastComponent()
    if parent == path || parent.isEmpty {
        return nil
    }
    return parent
}
