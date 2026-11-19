// Bounded, metadata-only discovery of configuration files under `$HOME`.
//
// Work is limited to:
// 1. the config paths of registry tools (``ToolRegistry/tools``), walked with depth and entry
//    limits;
// 2. the immediate children of `~/.config` (one `readdir`, `lstat` per child, never descended)
//    so tools without a registry entry surface with `tool == nil`;
// 3. the fixed ``ToolRegistry/wellKnownHomeEntries`` (`lstat` only).
// `$HOME` itself is never listed. Symlinks are reported, never followed: a symlinked directory
// is not descended, and a registry path below a symlinked ancestor (for example a symlinked
// `~/.config`) is not visited; the ancestor is reported instead. Only directories classified as
// ``ConfigClass/config`` are ever listed, so excluded directories (`~/.ssh`, `logs`, `.git`,
// caches, …) are reported but never opened. No file is ever opened.

import System

/// Discovers config files for the tools in `registry` under `home`.
///
/// - Parameters:
///   - home: Absolute `$HOME`.
///   - environment: `SHELL` / `PATH` values and binary/application search directories.
///   - limits: Depth and entry bounds; hitting one sets ``ConfigDiscoveryReport/truncated``.
///   - registry: Tool profiles to look for (defaults to ``ToolRegistry/tools``).
///   - fileSystem: Metadata-only filesystem access.
/// - Returns: Tools sorted by id and entries sorted by path.
public func discoverConfigs(
    home: FilePath,
    environment: ConfigDiscoveryEnvironment,
    limits: ConfigDiscoveryLimits = .default,
    registry: [ToolProfile] = ToolRegistry.tools,
    fileSystem: some DiscoveryFileSystem = DarwinDiscoveryFileSystem()
) -> ConfigDiscoveryReport {
    var walker = DiscoveryWalker(home: home, limits: limits, registry: registry, fileSystem: fileSystem)
    return walker.run(environment: environment)
}

private struct DiscoveryWalker<FS: DiscoveryFileSystem> {
    let home: FilePath
    let limits: ConfigDiscoveryLimits
    let registry: [ToolProfile]
    let fileSystem: FS

    var entries: [FilePath: DiscoveredEntry] = [:]
    var truncated = false
    var diagnostics: [Diagnostic] = []
    var presentRoots: [String: [FilePath]] = [:]

    init(home: FilePath, limits: ConfigDiscoveryLimits, registry: [ToolProfile], fileSystem: FS) {
        self.home = home
        self.limits = limits
        self.registry = registry.sorted { $0.id < $1.id }
        self.fileSystem = fileSystem
    }

    mutating func run(environment: ConfigDiscoveryEnvironment) -> ConfigDiscoveryReport {
        for tool in registry {
            for configPath in tool.configPaths {
                visitRoot(FilePath(configPath), tool: tool.id)
            }
        }
        for name in ToolRegistry.wellKnownHomeEntries {
            let relative = FilePath(name)
            visitRoot(relative, tool: ToolRegistry.owner(of: relative, in: registry)?.id)
        }
        visitXDGChildren()

        let tools = registry.compactMap { detect($0, environment: environment) }
        let sorted = entries.values.sorted { $0.path.string < $1.path.string }
        return ConfigDiscoveryReport(
            tools: tools, entries: sorted, truncated: truncated, diagnostics: diagnostics)
    }

    // MARK: Walking

    /// Visits a registry or well-known path, refusing to pass through a symlinked ancestor.
    mutating func visitRoot(_ relative: FilePath, tool: String?) {
        var ancestor = FilePath()
        for component in relative.components.dropLast() {
            ancestor.append(component)
            guard let meta = fileSystem.metadata(home.pushing(ancestor)) else { return }
            if meta.kind == .symlink {
                record(ancestor, tool: ToolRegistry.owner(of: ancestor, in: registry)?.id, meta: meta)
                return
            }
            if meta.kind != .directory { return }
        }
        guard let meta = fileSystem.metadata(home.pushing(relative)) else { return }
        if let tool {
            presentRoots[tool, default: []].append(home.pushing(relative))
        }
        visit(relative, tool: tool, meta: meta, depth: 0)
    }

    /// Reports the depth-1 children of `~/.config` that no registry path covers.
    mutating func visitXDGChildren() {
        let xdg = FilePath(ToolRegistry.xdgConfigDirectory)
        guard let meta = fileSystem.metadata(home.pushing(xdg)) else { return }
        guard meta.kind == .directory else {
            if meta.kind == .symlink { record(xdg, tool: nil, meta: meta) }
            return
        }
        guard let names = list(xdg) else { return }
        for name in names {
            let relative = xdg.appending(name)
            if entries[home.pushing(relative)] != nil { continue }
            guard let childMeta = fileSystem.metadata(home.pushing(relative)) else { continue }
            let owner = ToolRegistry.owner(of: relative, in: registry)?.id
            guard record(relative, tool: owner, meta: childMeta) else { return }
        }
    }

    mutating func visit(_ relative: FilePath, tool: String?, meta: DiscoveryMetadata, depth: Int) {
        guard record(relative, tool: tool, meta: meta) else { return }
        guard meta.kind == .directory, classifyConfigPath(relative).class == .config else { return }
        guard depth < limits.maxDepth else {
            truncated = true
            return
        }
        guard let names = list(relative) else { return }
        for name in names {
            let child = relative.appending(name)
            guard let childMeta = fileSystem.metadata(home.pushing(child)) else { continue }
            visit(child, tool: tool, meta: childMeta, depth: depth + 1)
            if truncated, entries.count >= limits.maxEntries { return }
        }
    }

    /// Lists a config directory: sorted names, capped at `maxEntriesPerDirectory`.
    mutating func list(_ relative: FilePath) -> [String]? {
        let path = home.pushing(relative)
        let names: [String]
        do {
            names = try fileSystem.listDirectory(path).sorted()
        } catch {
            diagnostics.append(
                Diagnostic.warning("Could not list '\(path.string)'").withDetail(error.description))
            return nil
        }
        if names.count > limits.maxEntriesPerDirectory {
            truncated = true
            return Array(names.prefix(limits.maxEntriesPerDirectory))
        }
        return names
    }

    /// Adds an entry unless it is already present. Returns `false` once the entry limit is hit.
    @discardableResult
    mutating func record(_ relative: FilePath, tool: String?, meta: DiscoveryMetadata) -> Bool {
        let path = home.pushing(relative)
        if entries[path] != nil { return true }
        guard entries.count < limits.maxEntries else {
            truncated = true
            return false
        }
        let classification = classifyConfigPath(relative)
        let isConfig = classification.class == .config
        var entry = DiscoveredEntry(
            path: path,
            relativePath: relative.string,
            tool: tool,
            kind: meta.kind,
            class: classification.class,
            excludedReason: classification.reason,
            sizeBytes: meta.kind == .file ? meta.size : nil)
        if isConfig, meta.kind == .file || meta.kind == .symlink {
            entry.language = detectConfigLanguage(relative)
        }
        if isConfig, meta.kind == .symlink, let destination = fileSystem.symlinkDestination(path) {
            entry.symlinkTarget = destination
            entry.symlinkOutsideHome = !resolvesInsideHome(destination, from: path)
        }
        entries[path] = entry
        return true
    }

    /// Lexically resolves a symlink destination against the link's directory (never touching the
    /// filesystem) and checks whether it stays below `home`.
    func resolvesInsideHome(_ destination: FilePath, from link: FilePath) -> Bool {
        let resolved = destination.isAbsolute
            ? destination.lexicallyNormalized()
            : link.removingLastComponent().pushing(destination).lexicallyNormalized()
        let normalizedHome = home.lexicallyNormalized()
        return resolved != normalizedHome && resolved.starts(with: normalizedHome)
    }

    // MARK: Detection

    func detect(_ tool: ToolProfile, environment: ConfigDiscoveryEnvironment) -> DetectedTool? {
        var sources: [ToolDetectionSource] = []
        if let shell = environment.shell, let name = FilePath(shell).lastComponent?.string,
            tool.shellNames.contains(name)
        {
            sources.append(.shell)
        }
        if tool.binaries.contains(where: { binaryExists($0, environment: environment) }) {
            sources.append(.binary)
        }
        let appDirectories = environment.applicationDirectories + [home.appending("Applications")]
        if tool.applications.contains(where: { app in
            appDirectories.contains { fileSystem.metadata($0.appending(app))?.kind == .directory }
        }) {
            sources.append(.application)
        }
        let roots = (presentRoots[tool.id] ?? []).sorted { $0.string < $1.string }
        if !roots.isEmpty {
            sources.append(.configPresent)
        }
        guard !sources.isEmpty else { return nil }
        return DetectedTool(id: tool.id, name: tool.name, detectedBy: sources, configRoots: roots)
    }

    func binaryExists(_ name: String, environment: ConfigDiscoveryEnvironment) -> Bool {
        let pathDirectories = (environment.path ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { FilePath(String($0)) }
            .filter(\.isAbsolute)
        for directory in pathDirectories + environment.binaryDirectories {
            switch fileSystem.metadata(directory.appending(name))?.kind {
            case .file?, .symlink?: return true
            default: continue
            }
        }
        return false
    }
}
