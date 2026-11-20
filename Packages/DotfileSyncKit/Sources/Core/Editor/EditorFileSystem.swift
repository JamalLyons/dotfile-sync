import Darwin
import Foundation
import System

func editorIO(_ operation: String, _ path: FilePath, code: Int32 = errno) -> EditorError {
    switch code {
    case ENOENT: return .notFound
    case EEXIST: return .alreadyExists
    case ELOOP: return .symlinkEscape
    case ENOTDIR, EISDIR: return .notRegularFile
    default: return .io(message: "\(operation) '\(path.string)': \(OSIOError(errno: code))")
    }
}

func editorCanonicalDirectory(
    _ path: FilePath, allowingMissing: Bool = false
) throws(EditorError) -> FilePath {
    var ancestor = path
    var missing: [FilePath.Component] = []
    while true {
        if let resolved = ancestor.withPlatformString({ realpath($0, nil) }) {
            defer { free(resolved) }
            let canonical = FilePath(platformString: resolved)
            _ = try EditorDirectory(opening: canonical)
            return canonical.appending(missing.reversed())
        }
        let code = errno
        guard allowingMissing, code == ENOENT, let last = ancestor.lastComponent else {
            throw editorIO("resolve directory", ancestor, code: code)
        }
        missing.append(last)
        ancestor.removeLastComponent()
    }
}

/// Each descent uses a single name relative to a directory descriptor.
final class EditorDirectory {
    let path: FilePath
    let fd: Int32

    init(opening path: FilePath) throws(EditorError) {
        let fd = path.withPlatformString { open($0, O_SEARCH | O_NOFOLLOW_ANY | O_CLOEXEC) }
        guard fd >= 0 else { throw editorIO("open directory", path) }
        self.path = path
        self.fd = fd
    }

    private init(path: FilePath, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    deinit { _ = close(fd) }

    func descend(
        _ components: FilePath.ComponentView, creatingWithMode mode: mode_t? = nil
    ) throws(EditorError) -> EditorDirectory {
        var parent = self
        for component in components {
            parent = try parent.child(component, creatingWithMode: mode)
        }
        return parent
    }

    private func child(
        _ name: FilePath.Component, creatingWithMode mode: mode_t?
    ) throws(EditorError) -> EditorDirectory {
        let childPath = path.appending(name)
        if try entry(name) == nil, let mode {
            try verifyLocation()
            if name.withPlatformString({ mkdirat(fd, $0, mode) }) != 0, errno != EEXIST {
                throw editorIO("create directory", childPath)
            }
        }
        guard let metadata = try entry(name) else { throw .notFound }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw .notRegularFile }
        let childFD = name.withPlatformString { openat(fd, $0, O_SEARCH | O_NOFOLLOW | O_CLOEXEC) }
        guard childFD >= 0 else { throw editorIO("open directory", childPath) }
        return EditorDirectory(path: childPath, fd: childFD)
    }

    /// Like lstat, without resolving the final name through a symlink.
    func entry(_ name: FilePath.Component) throws(EditorError) -> stat? {
        var metadata = stat()
        if name.withPlatformString({ fstatat(fd, $0, &metadata, AT_SYMLINK_NOFOLLOW) }) != 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw editorIO("inspect file", path.appending(name), code: code)
        }
        guard metadata.st_mode & S_IFMT != S_IFLNK else { throw .symlinkEscape }
        return metadata
    }

    func requireAbsent(_ name: FilePath.Component) throws(EditorError) {
        guard try entry(name) == nil else { throw .alreadyExists }
    }

    func verifyLocation() throws(EditorError) {
        let current = try EditorDirectory(opening: path)
        let original = try editorStat(fd, path)
        let observed = try editorStat(current.fd, path)
        guard editorSameInode(original, observed) else {
            throw .io(message: "directory moved during operation '\(path.string)'")
        }
    }

    func remove(_ name: FilePath.Component) {
        _ = name.withPlatformString { unlinkat(fd, $0, 0) }
    }
}

struct EditorSnapshot {
    let bytes: [UInt8]
    let metadata: stat
    let version: FileVersion

    var text: String? {
        guard !bytes.contains(0) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    var mode: mode_t { metadata.st_mode & 0o7777 }

    init(directory: EditorDirectory, name: FilePath.Component, limit: Int) throws(EditorError) {
        let path = directory.path.appending(name)
        guard let entry = try directory.entry(name) else { throw .notFound }
        try Self.checkFile(entry, limit: limit)
        let fd = name.withPlatformString {
            openat(directory.fd, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw editorIO("open file", path) }
        defer { _ = close(fd) }
        let opened = try editorStat(fd, path)
        try Self.checkFile(opened, limit: limit)
        guard editorSameInode(entry, opened) else { throw Self.changed(path) }

        let bytes = try Self.read(fd, path: path, limit: limit)
        let after = try editorStat(fd, path)
        try Self.checkFile(after, limit: limit)
        guard editorSameFileState(opened, after), bytes.count == after.st_size,
              let current = try directory.entry(name), editorSameFileState(after, current)
        else { throw Self.changed(path) }
        try directory.verifyLocation()

        self.bytes = bytes
        metadata = after
        version = try editorVersion(after, bytes: bytes)
    }

    private static func checkFile(_ metadata: stat, limit: Int) throws(EditorError) {
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile }
        let size = Int(metadata.st_size)
        guard size <= limit else { throw .tooLarge(limit: limit, size: size) }
    }

    private static func read(_ fd: Int32, path: FilePath, limit: Int) throws(EditorError) -> [UInt8] {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // Read at most one byte beyond the limit if the file grows after fstat.
            let capacity = min(buffer.count - 1, limit - bytes.count) + 1
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
            if count < 0 {
                if errno == EINTR { continue }
                throw editorIO("read file", path)
            }
            if count == 0 { return bytes }
            guard count <= limit - bytes.count else {
                let observedSize = Int(try editorStat(fd, path).st_size)
                throw .tooLarge(limit: limit, size: max(observedSize, bytes.count + count))
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func changed(_ path: FilePath) -> EditorError {
        .io(message: "file changed while reading '\(path.string)'")
    }
}

/// An exclusive sibling file, cleaned up on error and published by a single rename.
final class EditorStagedFile {
    private let directory: EditorDirectory
    private let name: FilePath.Component
    private var published = false
    let metadata: stat

    init(
        directory: EditorDirectory, bytes: [UInt8], preservingMode mode: mode_t? = nil
    ) throws(EditorError) {
        guard let name = FilePath.Component(".dotfilesync-editor-\(UUID().uuidString).tmp") else {
            throw .io(message: "could not represent temporary filename")
        }
        let path = directory.path.appending(name)
        try directory.verifyLocation()
        let fd = name.withPlatformString {
            openat(directory.fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw editorIO("create temporary file", path) }
        var ready = false
        defer {
            _ = close(fd)
            if !ready { directory.remove(name) }
        }
        if let error = writeAll(fd, bytes) {
            throw editorIO("write temporary file", path, code: error.errno)
        }
        if let mode, fchmod(fd, mode) != 0 {
            throw editorIO("set permissions", path)
        }
        while fsync(fd) != 0 {
            if errno != EINTR { throw editorIO("sync temporary file", path) }
        }
        metadata = try editorStat(fd, path)
        self.directory = directory
        self.name = name
        ready = true
    }

    deinit {
        if !published { directory.remove(name) }
    }

    func publish(as destination: FilePath.Component, replacing: Bool = false) throws(EditorError) {
        try requireStaged()
        try editorRename(
            directory.path.appending(name), directory.path.appending(destination), replacing: replacing
        )
        published = true
    }

    /// Replaces `destination` by swapping it with the staged file, then checks what was swapped out.
    ///
    /// A plain rename discards whatever is at `destination` at that instant, so a write that lands
    /// between the caller's last check and the rename is lost. Swapping makes the displaced file
    /// observable: it is now at the staged name and must still be exactly `expected` (same inode,
    /// size, mtime and contents). If it is not, the swap is reversed so the external writer's file is
    /// back at `destination` and the staged file is discarded, and the error is `.conflict`.
    ///
    /// Not prevented:
    /// - A writer that opened the old inode before the swap and writes through that descriptor after
    ///   the check passes. Its bytes land in the displaced inode, which is then unlinked (the backup
    ///   still holds the content copied before the swap). Without cooperative locking this cannot be
    ///   detected from outside the writer.
    /// - A write to the displaced inode between the check and the unlink, for the same reason.
    /// - A writer that replaces `destination` by rename while a conflict is being reversed. The
    ///   reversal then displaces that newer file to the staged name; it is left there and reported
    ///   in an `.io` error rather than deleted.
    /// - Volumes without `RENAME_SWAP`. These fall back to a single replacing rename, which keeps
    ///   the pre-swap window between the caller's check and the rename.
    func publishSwapping(
        as destination: FilePath.Component, expecting expected: EditorSnapshot, limit: Int
    ) throws(EditorError) {
        try requireStaged()
        let stagedPath = directory.path.appending(name)
        let destinationPath = directory.path.appending(destination)
        switch try editorSwap(stagedPath, destinationPath) {
        case .unsupported:
            try editorRename(stagedPath, destinationPath, replacing: true)
            published = true
            return
        case .swapped:
            break
        }
        // From here the staged name may hold the displaced file, which can be an external writer's
        // version; it must never be removed by cleanup, only by the explicit paths below.
        published = true
        guard let afterSwap = try directory.entry(name) else {
            // Some volumes (FAT) accept RENAME_SWAP but perform a plain replace: the staged name is
            // gone and the destination already holds our file. That is the same outcome, and the
            // same pre-swap window, as the unsupported fallback.
            return
        }
        guard !editorSameInode(afterSwap, metadata) else {
            throw .io(message: "swap did not exchange '\(destinationPath.string)'; the file was not replaced")
        }
        // The staged name now holds the file that was at the destination.
        let displaced: Result<EditorSnapshot, EditorError>
        do throws(EditorError) {
            displaced = .success(try EditorSnapshot(directory: directory, name: name, limit: limit))
        } catch {
            displaced = .failure(error)
        }
        if case let .success(snapshot) = displaced, Self.isUnchanged(snapshot, expected) {
            directory.remove(name)
            return
        }

        let restored: EditorSwapOutcome
        do throws(EditorError) {
            restored = try editorSwap(stagedPath, destinationPath)
        } catch {
            throw .io(
                message: "could not restore externally modified file (\(error)); it is preserved at '\(stagedPath.string)'"
            )
        }
        guard case .swapped = restored else {
            // The swap succeeded a moment ago, so this only happens if the filesystem changed.
            throw .io(message: "could not restore externally modified file; it is preserved at '\(stagedPath.string)'")
        }
        // The staged name must hold our file again. If not, a newer external file was displaced.
        if let back = try? directory.entry(name), editorSameInode(back, metadata) {
            directory.remove(name)
            switch displaced {
            case let .success(snapshot): throw .conflict(current: snapshot.version)
            case let .failure(error): throw error
            }
        }
        throw .io(
            message: "file changed during save; the newer version is preserved at '\(stagedPath.string)'"
        )
    }

    private func requireStaged() throws(EditorError) {
        guard let current = try directory.entry(name), editorSameFileState(current, metadata) else {
            throw .io(message: "temporary file changed before rename '\(directory.path.appending(name).string)'")
        }
    }

    private static func isUnchanged(_ observed: EditorSnapshot, _ expected: EditorSnapshot) -> Bool {
        editorSameInode(observed.metadata, expected.metadata)
            && observed.metadata.st_size == expected.metadata.st_size
            && observed.metadata.st_mtimespec.tv_sec == expected.metadata.st_mtimespec.tv_sec
            && observed.metadata.st_mtimespec.tv_nsec == expected.metadata.st_mtimespec.tv_nsec
            && observed.bytes == expected.bytes
    }
}

enum EditorSwapOutcome { case swapped, unsupported }

/// Atomically exchanges two names. Both must exist.
func editorSwap(_ first: FilePath, _ second: FilePath) throws(EditorError) -> EditorSwapOutcome {
    let flags = UInt32(RENAME_NOFOLLOW_ANY | RENAME_SWAP)
    let result = first.withPlatformString { source in
        second.withPlatformString { destination in
            renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, flags)
        }
    }
    if result == 0 { return .swapped }
    let code = errno
    if code == ENOTSUP || code == EINVAL { return .unsupported }
    throw editorIO("swap files", second, code: code)
}

func editorRename(_ from: FilePath, _ to: FilePath, replacing: Bool = false) throws(EditorError) {
    let flags = UInt32(RENAME_NOFOLLOW_ANY | (replacing ? 0 : RENAME_EXCL))
    let result = from.withPlatformString { source in
        to.withPlatformString { destination in
            renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, flags)
        }
    }
    guard result == 0 else { throw editorIO("rename file", to) }
}

func editorVersion(_ metadata: stat, bytes: [UInt8]) throws(EditorError) -> FileVersion {
    let (seconds, secondsOverflow) = Int64(metadata.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
    let (mtime, nanosOverflow) = seconds.addingReportingOverflow(Int64(metadata.st_mtimespec.tv_nsec))
    guard !secondsOverflow, !nanosOverflow else {
        throw .io(message: "file modification time is out of range")
    }
    return FileVersion(mtimeNs: mtime, size: Int(metadata.st_size), sha256: sha256Hex(bytes))
}

private func editorStat(_ fd: Int32, _ path: FilePath) throws(EditorError) -> stat {
    var metadata = stat()
    guard fstat(fd, &metadata) == 0 else { throw editorIO("inspect open file", path) }
    return metadata
}

func editorSameInode(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
}

func editorSameFileState(_ lhs: stat, _ rhs: stat) -> Bool {
    editorSameInode(lhs, rhs) && lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode
        && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
        && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}
