import Darwin
import System

/// Compares a HOME-relative or absolute HOME target against its managed repository source.
/// Unmanaged files and files without a repository source return `.noBase` without loading
/// machine file contents. Excluded paths throw `.excluded` before either side is opened.
/// `report` can supply the same discovery classifications used to build the tree.
public func diffWorkingFile(
    target: FilePath, resolved: ResolvedManifest, home: FilePath, repoRoot: FilePath,
    report: ConfigDiscoveryReport? = nil, maxBytes: Int = 1_048_576
) throws(WorkingTreeError) -> ConfigFileDiff {
    let paths = WorkingTreePaths(report: report, resolved: resolved, home: home, repoRoot: repoRoot)
    return try diffWorkingFile(
        target: target, paths: paths, maxBytes: maxBytes, prepareBase: repositoryDiffBase(read: readDiffFile),
        readTarget: readDiffFile)
}

enum WorkingFileContents {
    case missing
    case tooLarge
    case bytes([UInt8])
}

typealias WorkingFileReader = (FilePath, Int) throws(WorkingTreeError) -> WorkingFileContents

struct WorkingFileBase {
    /// The current repo source a tracked target may point to, when it exists.
    let repositorySource: FilePath?
    let read: (Int) throws(WorkingTreeError) -> WorkingFileContents
}

/// Prepares a base by repo-relative path without opening its contents. A provider can supply
/// bytes for a path that does not exist in the repository's working directory.
typealias WorkingFileBaseProvider = (FilePath, WorkingTreePaths) throws(WorkingTreeError) -> WorkingFileBase?

func repositoryDiffBase(read: @escaping WorkingFileReader) -> WorkingFileBaseProvider {
    { relative, paths throws(WorkingTreeError) in
        guard let source = try paths.sourceLocation(relative) else { return nil }
        return WorkingFileBase(repositorySource: source) { limit throws(WorkingTreeError) in
            try read(source, limit)
        }
    }
}

func diffWorkingFile(
    target: FilePath, paths: WorkingTreePaths, maxBytes: Int,
    prepareBase: WorkingFileBaseProvider, readTarget: WorkingFileReader
) throws(WorkingTreeError) -> ConfigFileDiff {
    guard maxBytes >= 0 else { throw .invalidByteLimit }
    let relative = try paths.targetRelativePath(target)
    let entry = paths.tracked[relative]
    guard paths.targetExclusion(relative, entry: entry) == nil else { throw .excluded }

    func result(
        _ status: ConfigFileDiffStatus, targetMissing: Bool = false,
        additions: Int = 0, deletions: Int = 0, hunks: [ConfigDiffHunk] = []
    ) -> ConfigFileDiff {
        ConfigFileDiff(
            relativePath: relative.string, managedSource: entry?.source, status: status,
            targetMissing: targetMissing, additions: additions, deletions: deletions, hunks: hunks)
    }

    guard let entry, let prepared = try prepareBase(paths.sourceRelativePath(entry), paths) else {
        return result(.noBase)
    }
    let destination = try paths.targetLocation(relative, source: prepared.repositorySource)
    let base: [UInt8]
    switch try prepared.read(maxBytes) {
    case .missing: return result(.noBase)
    case .tooLarge: return result(.tooLarge)
    case let .bytes(bytes): base = bytes
    }

    let current = try destination.map { path throws(WorkingTreeError) in
        try readTarget(path, maxBytes)
    } ?? .missing
    let machine: [UInt8]
    let targetMissing: Bool
    switch current {
    case .tooLarge: return result(.tooLarge)
    case .missing:
        machine = []
        targetMissing = true
    case let .bytes(bytes):
        machine = bytes
        targetMissing = false
    }

    guard isDiffText(base), isDiffText(machine) else { return result(.binary) }
    if base == machine {
        return targetMissing ? result(.changed, targetMissing: true) : result(.unchanged)
    }
    guard let edits = lineEdits(from: base, to: machine) else { return result(.tooComplex) }
    return result(
        .changed, targetMissing: targetMissing, additions: edits.additions, deletions: edits.deletions,
        hunks: edits.hunks)
}

private func isDiffText(_ bytes: [UInt8]) -> Bool {
    !bytes.contains(0) && String(validating: bytes, as: UTF8.self) != nil
}

private func readDiffFile(_ path: FilePath, _ limit: Int) throws(WorkingTreeError) -> WorkingFileContents {
    let fd = path.withPlatformString { open($0, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC) }
    guard fd >= 0 else {
        let error = OSIOError.current()
        if error.errno == ENOENT { return .missing }
        throw workingTreeIO(error)
    }
    defer { _ = close(fd) }
    var metadata = stat()
    guard fstat(fd, &metadata) == 0 else { throw workingTreeIO(.current()) }
    guard metadata.st_mode & S_IFMT == S_IFREG else { throw .unsafePath }
    guard metadata.st_size <= limit else { return .tooLarge }

    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        // One extra byte detects a file that grew after fstat.
        let capacity = min(buffer.count - 1, limit - bytes.count) + 1
        let readCount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
        if readCount < 0 {
            if errno == EINTR { continue }
            throw workingTreeIO(.current())
        }
        if readCount == 0 { return .bytes(bytes) }
        guard readCount <= limit - bytes.count else { return .tooLarge }
        bytes.append(contentsOf: buffer.prefix(readCount))
    }
}
