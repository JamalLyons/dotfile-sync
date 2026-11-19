import Core
import Foundation
import IPC
import System

struct ConfigOperations: Sendable {
    let config: AgentConfig
    let locks: ResourceLocks
    let log: Logger
    private let environment = ConfigDiscoveryEnvironment(environment: ProcessInfo.processInfo.environment)

    init(config: AgentConfig, locks: ResourceLocks, log: Logger) {
        self.config = config
        self.locks = locks
        self.log = log
    }

    func discover(home: FilePath?) throws(ProtocolError) -> ConfigDiscoveryReport {
        let home = home ?? config.home
        try validatePath("home", home)
        let guardLock = try lock([(.homeDirectory(home), .shared)])
        defer { guardLock.release() }
        return discoverConfigs(home: home, environment: environment)
    }

    func tree(
        manifest: FilePath, home: FilePath?, repoRoot: FilePath?, profile: String?
    ) throws(ProtocolError) -> WorkingTree {
        try withWorkingTree(manifest: manifest, home: home, repoRoot: repoRoot, profile: profile) {
            report, resolved, home, repoRoot in
            buildWorkingTree(report: report, resolved: resolved, home: home, repoRoot: repoRoot)
        }
    }

    func diff(
        target: FilePath, manifest: FilePath, home: FilePath?, repoRoot: FilePath?, profile: String?
    ) throws(ProtocolError) -> ConfigFileDiff {
        guard !target.isEmpty, target.string.utf8.count <= MAX_PATH_BYTES else {
            throw ProtocolError(.invalidParams, "'target' must be 1..=\(MAX_PATH_BYTES) bytes")
        }
        return try withWorkingTree(manifest: manifest, home: home, repoRoot: repoRoot, profile: profile) {
            report, resolved, home, repoRoot throws(ProtocolError) in
            do throws(WorkingTreeError) {
                return try diffWorkingFile(target: target, resolved: resolved, home: home, repoRoot: repoRoot, report: report)
            } catch {
                throw treeError(error)
            }
        }
    }

    private func withWorkingTree<T>(
        manifest: FilePath, home: FilePath?, repoRoot: FilePath?, profile: String?,
        _ read: (ConfigDiscoveryReport, ResolvedManifest, FilePath, FilePath) throws(ProtocolError) -> T
    ) throws(ProtocolError) -> T {
        let input = PlanInput(manifest: manifest, home: home ?? config.home, repoRoot: repoRoot, profile: profile)
        try validatePlanInput(input)
        let guardLock = try lock([(.homeDirectory(input.home), .shared), (.manifestPath(manifest), .shared)])
        defer { guardLock.release() }
        let resolved: ResolvedManifest
        do {
            resolved = try resolveProfile(
                loadManifest(manifest.string), selection: profile.map(ProfileSelection.explicit) ?? .auto,
                hostname: currentHostname(), os: currentOs()
            )
        } catch {
            throw ProtocolError(.invalidParams, error.description)
        }
        let report = discoverConfigs(home: input.home, environment: environment)
        return try read(report, resolved, input.home, defaultRepoRoot(manifest: manifest, repoRoot: repoRoot))
    }

    func open(path: String) throws(ProtocolError) -> ConfigDocument {
        try requireEditable([path])
        let guardLock = try lock([(.homeDirectory(config.home), .shared)])
        defer { guardLock.release() }
        do {
            return ConfigDocument(try makeEditor().open(path: path))
        } catch {
            throw editorError(error)
        }
    }

    func edit(
        paths: [String],
        _ write: (ConfigEditor) throws(EditorError) -> EditorWriteReport,
        shuttingDown: () -> Bool
    ) throws(ProtocolError) -> ConfigWriteReport {
        try requireEditable(paths)
        let guardLock = try lock([(.homeDirectory(config.home), .exclusive)], cancelled: shuttingDown)
        defer { guardLock.release() }
        guard !shuttingDown() else {
            throw ProtocolError(.shuttingDown, "daemon is shutting down")
        }
        let report: EditorWriteReport
        do {
            report = try write(makeEditor())
        } catch {
            throw editorError(error)
        }
        log.info("config write path=\(report.path.string) backup_path=\(report.backupPath?.string ?? "none")")
        // Publish successful editor changes here when sync (#6) and the watcher (#7) are wired up.
        return ConfigWriteReport(report)
    }

    /// Refuses secret-like, cache, data and generated paths before the editor opens anything,
    /// so excluded content is never read, hashed or written (issue #11 consent rule). The
    /// editor still enforces root confinement; this only adds the classification gate.
    private func requireEditable(_ paths: [String]) throws(ProtocolError) {
        for raw in paths {
            guard !raw.utf8.contains(0) else {
                throw ProtocolError(.invalidParams, "path contains parent traversal or a NUL byte")
            }
            var relative = FilePath(raw).lexicallyNormalized()
            guard relative.removePrefix(config.home.lexicallyNormalized()) else { continue }
            let classification = classifyConfigPath(relative)
            if classification.class.isExcludedByDefault {
                throw ProtocolError(
                    .invalidParams,
                    "'\(raw)' is \(classification.class.rawValue) and excluded from editing: \(classification.reason ?? "excluded")"
                )
            }
        }
    }

    private func makeEditor() throws(EditorError) -> ConfigEditor {
        let fs = DarwinDiscoveryFileSystem()
        let report = discoverConfigs(
            home: config.home, environment: environment, limits: ConfigDiscoveryLimits(maxDepth: 0), fileSystem: fs
        )
        let directories = Set(report.entries.filter { $0.kind == .directory }.map(\.path))
        let roots = report.tools.flatMap(\.configRoots).filter { directories.contains($0) }
        do {
            _ = try checkPrivateDir(config.layout.editorBackupsDir)
        } catch {
            throw .io(message: error.description)
        }
        return try ConfigEditor(
            allowedRoots: roots, backupRoot: config.layout.editorBackupsDir, now: nowMs,
            confiningRootsTo: config.home
        )
    }

    private func lock(
        _ requests: [(ResourceKey, LockMode)], cancelled: () -> Bool = { false }
    ) throws(ProtocolError) -> LockGuard {
        do {
            return try locks.acquire(requests, cancelled: cancelled)
        } catch {
            throw ProtocolError(.shuttingDown, "daemon is shutting down")
        }
    }
}

private func editorError(_ error: EditorError) -> ProtocolError {
    switch error {
    case .outsideRoots: return ProtocolError(.invalidParams, "path is outside the agent's discovered config roots")
    case .pathTraversal: return ProtocolError(.invalidParams, "path contains parent traversal or a NUL byte")
    case .symlinkEscape: return ProtocolError(.invalidParams, "config paths must not pass through a symlink")
    case .notRegularFile: return ProtocolError(.invalidParams, "path must identify a regular file")
    case let .tooLarge(limit, size): return ProtocolError(.invalidParams, "file size \(size) exceeds the \(limit)-byte editor limit")
    case .binaryFile: return ProtocolError(.invalidParams, "binary files cannot be saved as text")
    case let .conflict(current):
        let conflict = ProtocolError(.conflict, "file changed since it was opened")
        guard let version = try? jsonValue(current) else { return conflict }
        return conflict.withDetails(.object([("current_version", version)]))
    case .alreadyExists: return ProtocolError(.conflict, "destination already exists")
    case .notFound: return ProtocolError(.notFound, "config file or parent directory was not found")
    case let .io(message): return ProtocolError(.internal, message)
    }
}

private func treeError(_ error: WorkingTreeError) -> ProtocolError {
    switch error {
    case .excluded: return ProtocolError(.invalidParams, "target is excluded from the config tree")
    case .invalidTarget: return ProtocolError(.invalidParams, "target must identify a file inside HOME")
    case .invalidByteLimit: return ProtocolError(.invalidParams, "invalid diff byte limit")
    case .unsafePath: return ProtocolError(.invalidParams, "diff requires a confined path to a regular file")
    case let .io(message): return ProtocolError(.internal, message)
    }
}
