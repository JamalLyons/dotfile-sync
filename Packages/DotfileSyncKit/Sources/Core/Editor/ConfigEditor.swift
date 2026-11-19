import Darwin
import Foundation
import Synchronization
import System

/// Reads and edits regular files within configured directory roots.
///
/// Raw paths should use the String overloads. FilePath's string initializer discards everything
/// from the first NUL onward, so it cannot be used to validate raw input.
public struct ConfigEditor: Sendable {
    // Serialize check-and-write sequences across editors in this process, including root aliases.
    private static let writes = Mutex(())
    private let roots: [(alias: FilePath, canonical: FilePath)]
    private let backupRoot: FilePath
    private let maxFileSize: Int
    private let now: @Sendable () -> UInt64

    /// Configures the editor with existing absolute directory roots and an absolute backup path.
    ///
    /// Roots are resolved once. Both the configured spelling and the resolved path are accepted.
    /// A missing backup directory is created on first save. The clock returns Unix milliseconds
    /// for UTC backup names. The size limit is measured in bytes.
    public init(
        allowedRoots: [FilePath],
        backupRoot: FilePath,
        maxFileSize: Int = 1_048_576,
        now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1_000) }
    ) throws(EditorError) {
        try self.init(allowedRoots: allowedRoots, backupRoot: backupRoot, maxFileSize: maxFileSize, now: now, confiningRootsTo: nil)
    }

    /// For discovery-derived roots, refuse directory aliases below the trusted home.
    package init(
        allowedRoots: [FilePath],
        backupRoot: FilePath,
        maxFileSize: Int = 1_048_576,
        now: @escaping @Sendable () -> UInt64,
        confiningRootsTo home: FilePath?
    ) throws(EditorError) {
        guard maxFileSize >= 0 else { throw .io(message: "max file size must be nonnegative") }
        let home = try home.map { path throws(EditorError) in try Self.validate(path) }
        let canonicalHome = try home.map { path throws(EditorError) in try editorCanonicalDirectory(path) }
        var roots: [(alias: FilePath, canonical: FilePath)] = []
        for root in allowedRoots {
            let alias = try Self.validate(root)
            let canonical = try editorCanonicalDirectory(alias)
            if let home, let canonicalHome {
                var relative = alias
                guard relative.removePrefix(home), !relative.isEmpty else { throw .outsideRoots }
                guard canonical == canonicalHome.pushing(relative) else { throw .symlinkEscape }
            }
            roots.append((alias, canonical))
            if alias != canonical { roots.append((canonical, canonical)) }
        }
        self.roots = roots.sorted { $0.alias.components.count > $1.alias.components.count }
        self.backupRoot = try editorCanonicalDirectory(Self.validate(backupRoot), allowingMissing: true)
        self.maxFileSize = maxFileSize
        self.now = now
    }

    /// Reads a confined file. Binary documents have bytes and a version but no editable text.
    public func open(path: FilePath) throws(EditorError) -> EditorDocument {
        let location = try locate(path)
        let directory = try location.openParent()
        let snapshot = try EditorSnapshot(directory: directory, name: location.name, limit: maxFileSize)
        return EditorDocument(
            path: path, bytes: snapshot.bytes, text: snapshot.text, mode: UInt32(snapshot.mode), version: snapshot.version
        )
    }

    /// Validates a raw path and opens the document.
    public func open(path: String) throws(EditorError) -> EditorDocument {
        try open(path: Self.path(from: path))
    }

    /// Copies the current file to the backup directory, then atomically replaces it.
    /// Set `force` to explicitly allow a stale version. All other checks still apply.
    public func save(
        path: FilePath, text: String, expectedVersion: FileVersion, force: Bool = false
    ) throws(EditorError) -> EditorWriteReport {
        let location = try locate(path)
        let bytes = try checkedText(text)
        let stamp = formatStamp(now())
        return try Self.writes.withLock { _ throws(EditorError) in
            let directory = try location.openParent()
            let current = try EditorSnapshot(directory: directory, name: location.name, limit: maxFileSize)
            guard force || current.version == expectedVersion else { throw .conflict(current: current.version) }
            guard current.text != nil else { throw .binaryFile }

            let replacement = try EditorStagedFile(directory: directory, bytes: bytes, preservingMode: current.mode)
            let version = try editorVersion(replacement.metadata, bytes: bytes)
            let backup = try copyBackup(of: current, relativeToRoot: location, stamp: stamp)
            do throws(EditorError) {
                try verifyUnchanged(current, directory: directory, name: location.name)
                try replacement.publish(as: location.name, replacing: true)
            } catch {
                if let entry = try? backup.directory.entry(backup.name), editorSameInode(entry, backup.metadata) {
                    backup.directory.remove(backup.name)
                }
                throw error
            }
            return EditorWriteReport(
                path: path, backupPath: backup.directory.path.appending(backup.name), newVersion: version
            )
        }
    }

    /// Validates a raw path and saves the document.
    public func save(
        path: String, text: String, expectedVersion: FileVersion, force: Bool = false
    ) throws(EditorError) -> EditorWriteReport {
        try save(path: Self.path(from: path), text: text, expectedVersion: expectedVersion, force: force)
    }

    /// Creates a new UTF-8 file with private permissions and creates missing parents within its root.
    public func create(path: FilePath, text: String) throws(EditorError) -> EditorWriteReport {
        let location = try locate(path)
        let bytes = try checkedText(text)
        return try Self.writes.withLock { _ throws(EditorError) in
            let directory = try location.openParent(creatingWithMode: 0o755)
            try directory.requireAbsent(location.name)
            let file = try EditorStagedFile(directory: directory, bytes: bytes)
            let version = try editorVersion(file.metadata, bytes: bytes)
            try file.publish(as: location.name)
            return EditorWriteReport(path: path, backupPath: nil, newVersion: version)
        }
    }

    /// Validates a raw path and creates the file.
    public func create(path: String, text: String) throws(EditorError) -> EditorWriteReport {
        try create(path: Self.path(from: path), text: text)
    }

    /// Moves a regular file within one resolved root. The destination parent must already exist.
    /// The destination must be absent, and the source must fit within the size limit.
    public func rename(from: FilePath, to: FilePath) throws(EditorError) -> EditorWriteReport {
        let source = try locate(from)
        let destination = try locate(to)
        guard source.root == destination.root else { throw .outsideRoots }
        return try Self.writes.withLock { _ throws(EditorError) in
            let fromDirectory = try source.openParent()
            let toDirectory = try destination.openParent()
            try toDirectory.requireAbsent(destination.name)
            let snapshot = try EditorSnapshot(directory: fromDirectory, name: source.name, limit: maxFileSize)
            try toDirectory.verifyLocation()
            try verifyUnchanged(snapshot, directory: fromDirectory, name: source.name)
            try editorRename(fromDirectory.path.appending(source.name), toDirectory.path.appending(destination.name))
            return EditorWriteReport(path: to, backupPath: nil, newVersion: snapshot.version)
        }
    }

    /// Validates raw paths and renames the source file.
    public func rename(from: String, to: String) throws(EditorError) -> EditorWriteReport {
        try rename(from: Self.path(from: from), to: Self.path(from: to))
    }

    private static func path(from rawPath: String) throws(EditorError) -> FilePath {
        guard !rawPath.utf8.contains(0) else { throw .pathTraversal }
        return FilePath(rawPath)
    }

    private static func validate(_ path: FilePath) throws(EditorError) -> FilePath {
        guard path.isAbsolute else { throw .outsideRoots }
        guard !path.components.contains(where: { $0.kind == .parentDirectory }) else { throw .pathTraversal }
        return path.lexicallyNormalized()
    }

    private func locate(_ path: FilePath) throws(EditorError) -> EditorLocation {
        let normalized = try Self.validate(path)
        for root in roots {
            var relative = normalized
            guard relative.removePrefix(root.alias) else { continue }
            guard path.lastComponent?.kind != .currentDirectory, let name = relative.lastComponent else {
                throw .notRegularFile
            }
            return EditorLocation(root: root.canonical, parent: relative.removingLastComponent(), name: name)
        }
        throw .outsideRoots
    }

    private func checkedText(_ text: String) throws(EditorError) -> [UInt8] {
        let size = text.utf8.count
        guard size <= maxFileSize else { throw .tooLarge(limit: maxFileSize, size: size) }
        guard !text.utf8.contains(0) else { throw .binaryFile }
        return Array(text.utf8)
    }

    private func verifyUnchanged(
        _ snapshot: EditorSnapshot, directory: EditorDirectory, name: FilePath.Component
    ) throws(EditorError) {
        try directory.verifyLocation()
        guard let observed = try directory.entry(name) else { throw .notFound }
        if !editorSameFileState(snapshot.metadata, observed) {
            let current = try EditorSnapshot(directory: directory, name: name, limit: maxFileSize)
            throw .conflict(current: current.version)
        }
    }

    private func copyBackup(
        of snapshot: EditorSnapshot, relativeToRoot location: EditorLocation, stamp: String
    ) throws(EditorError) -> (directory: EditorDirectory, name: FilePath.Component, metadata: stat) {
        let backup = try EditorDirectory(opening: "/").descend(backupRoot.components, creatingWithMode: 0o700)
        let directory = try backup.descend(location.parent.components, creatingWithMode: 0o700)
        let file = try EditorStagedFile(directory: directory, bytes: snapshot.bytes)
        let originalName = pathBytes(FilePath().appending(location.name))
        var index = 0
        while true {
            let suffix = index == 0 ? ".backup.\(stamp)" : ".backup.\(stamp).\(index)"
            guard let name = filePath(fromBytes: originalName + suffix.utf8).lastComponent else {
                throw .io(message: "could not represent backup filename")
            }
            do throws(EditorError) {
                try file.publish(as: name)
                return (directory, name, file.metadata)
            } catch {
                guard error == .alreadyExists else { throw error }
                index += 1
            }
        }
    }
}

private struct EditorLocation {
    let root: FilePath
    let parent: FilePath
    let name: FilePath.Component

    func openParent(creatingWithMode mode: mode_t? = nil) throws(EditorError) -> EditorDirectory {
        try EditorDirectory(opening: root).descend(parent.components, creatingWithMode: mode)
    }
}
