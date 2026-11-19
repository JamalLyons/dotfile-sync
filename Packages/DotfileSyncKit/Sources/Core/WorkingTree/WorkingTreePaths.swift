import Darwin
import System

struct WorkingTreePaths {
    let home: FilePath
    let repoRoot: FilePath
    let discovered: [FilePath: DiscoveredEntry]
    let tracked: [FilePath: TrackedFile]

    private let excludedPaths: [(raw: String, expanded: FilePath)]
    private let patterns: [GlobPattern]
    private let overrides: Set<FilePath>

    init(report: ConfigDiscoveryReport?, resolved: ResolvedManifest, home: FilePath, repoRoot: FilePath) {
        self.home = home.lexicallyNormalized()
        self.repoRoot = repoRoot.lexicallyNormalized()
        discovered = Self.index(report?.entries ?? []) { Self.relative($0.path, to: home) }
        tracked = Self.index(resolved.files) { Self.relative(expandTargetPath($0.target, homeDir: home), to: home) }
        excludedPaths = resolved.exclusions.paths.map { ($0, expandTargetPath($0, homeDir: home)) }
        patterns = resolved.exclusions.patterns.compactMap(GlobPattern.init)
        overrides = Set(resolved.overrides.compactMap {
            Self.relative(expandTargetPath($0.target, homeDir: home), to: home)
        })
    }

    func targetRelativePath(_ target: FilePath) throws(WorkingTreeError) -> FilePath {
        let absolute = target.isAbsolute ? target : home.pushing(target)
        guard let relative = Self.relative(absolute, to: home) else { throw .invalidTarget }
        return relative
    }

    func classification(_ relative: FilePath) -> ConfigClassification {
        let classified = classifyConfigPath(relative)
        if classified.class == .secretLike { return classified }
        var path = relative
        while !path.isEmpty {
            if let entry = discovered[path], entry.isExcluded {
                return ConfigClassification(class: entry.class, reason: entry.excludedReason ?? "Excluded by discovery")
            }
            path.removeLastComponent()
        }
        return classified
    }

    func targetExclusion(_ relative: FilePath, entry: TrackedFile?) -> String? {
        if let reason = classification(relative).reason { return reason }
        if entry?.machineLocal == true || overrides.contains(relative) { return "Machine-local override" }

        var path = relative
        while !path.isEmpty {
            let raw = path == relative ? entry?.target : nil
            if manifestExcludes(path, under: home, raw: raw, homeRelative: true) {
                return "Excluded by manifest"
            }
            path.removeLastComponent()
        }
        return nil
    }

    func sourceRelativePath(_ entry: TrackedFile) throws(WorkingTreeError) -> FilePath {
        let raw = decodeManifestPathBytes(entry.source)
        guard !raw.isAbsolute, let relative = Self.relative(repoRoot.pushing(raw), to: repoRoot) else {
            throw .unsafePath
        }
        try checkSourceExclusions(relative, raw: entry.source)
        return relative
    }

    /// Resolves the source without opening it. Confined repository symlinks are supported.
    func sourceLocation(_ relative: FilePath) throws(WorkingTreeError) -> FilePath? {
        guard let root = try existingPath(repoRoot), let final = try existingPath(root.pushing(relative)) else {
            return nil
        }
        guard let resolved = Self.relative(final, to: root) else { throw .unsafePath }
        try checkSourceExclusions(resolved, raw: nil)
        if let canonicalHome = try? canonicalize(home),
           let homePath = Self.relative(final, to: canonicalHome), targetExclusion(homePath, entry: tracked[homePath]) != nil {
            throw .excluded
        }
        try requireRegularFile(final)
        return final
    }

    /// Resolves a HOME file, or a leaf symlink to its own repository source.
    func targetLocation(
        _ relative: FilePath, source: FilePath?
    ) throws(WorkingTreeError) -> FilePath? {
        guard let root = try existingPath(home), let name = relative.lastComponent else { return nil }
        let parent = root.pushing(relative.removingLastComponent())
        guard let resolvedParent = try existingPath(parent) else { return nil }
        if resolvedParent != root {
            guard let resolved = Self.relative(resolvedParent, to: root) else { throw .unsafePath }
            guard targetExclusion(resolved.appending(name), entry: nil) == nil else { throw .excluded }
        }
        guard rustPathEqual(parent, resolvedParent) else { throw .unsafePath }

        let path = parent.appending(name)
        switch lstatPath(path) {
        case let .success(metadata) where metadata.st_mode & S_IFMT == S_IFLNK:
            guard let resolved = try existingPath(path) else { throw .unsafePath }
            if let destination = Self.relative(resolved, to: root), targetExclusion(destination, entry: nil) != nil {
                throw .excluded
            }
            guard let source, rustPathEqual(resolved, source) else { throw .unsafePath }
            return source
        case let .success(metadata) where metadata.st_mode & S_IFMT == S_IFREG:
            guard let resolved = try existingPath(path) else { return nil }
            guard let destination = Self.relative(resolved, to: root) else { throw .unsafePath }
            guard targetExclusion(destination, entry: nil) == nil else { throw .excluded }
            guard rustPathEqual(resolved, path) else { throw .unsafePath }
            return resolved
        case .success:
            throw .unsafePath
        case let .failure(error) where error.errno == ENOENT:
            return nil
        case let .failure(error):
            throw workingTreeIO(error)
        }
    }

    private func checkSourceExclusions(_ relative: FilePath, raw: String?) throws(WorkingTreeError) {
        guard !classifyConfigPath(relative).class.isExcludedByDefault else { throw .excluded }
        var path = relative
        while !path.isEmpty {
            if manifestExcludes(path, under: repoRoot, raw: path == relative ? raw : nil, homeRelative: false) {
                throw .excluded
            }
            path.removeLastComponent()
        }
    }

    // ConfigInspector's matcher is private. Use its path equality/suffix and glob rules,
    // plus HOME-relative spellings so discovered paths can use the same manifest filters.
    private func manifestExcludes(
        _ relative: FilePath, under root: FilePath, raw: String?, homeRelative: Bool
    ) -> Bool {
        let absolute = root.pushing(relative)
        let relativeString = relative.string
        let homeString = "~/" + relativeString
        if excludedPaths.contains(where: { path in
            path.raw == raw || rustPathEqual(path.expanded, absolute) || rustPathEndsWith(absolute, path.raw)
                || (raw.map { rustPathEndsWith(bytes: Array($0.utf8), path.raw) } ?? false)
        }) {
            return true
        }
        let name = rustFileName(relative).flatMap { String(validating: $0, as: UTF8.self) }
        return patterns.contains { pattern in
            (raw.map(pattern.matches) ?? false) || (name.map(pattern.matches) ?? false)
                || pattern.matches(relativeString) || (homeRelative && pattern.matches(homeString))
        }
    }

    private static func relative(_ path: FilePath, to root: FilePath) -> FilePath? {
        guard path.isAbsolute, root.isAbsolute,
              !path.components.contains(where: { $0.kind == .parentDirectory }) else { return nil }
        var relative = path.lexicallyNormalized()
        guard relative.removePrefix(root.lexicallyNormalized()), !relative.isEmpty else { return nil }
        return relative
    }

    private static func index<Value>(_ values: [Value], by key: (Value) -> FilePath?) -> [FilePath: Value] {
        var indexed: [FilePath: Value] = [:]
        for value in values {
            if let path = key(value) { indexed[path] = value }
        }
        return indexed
    }
}

private func existingPath(_ path: FilePath) throws(WorkingTreeError) -> FilePath? {
    do {
        return try canonicalize(path)
    } catch {
        if error.errno == ENOENT { return nil }
        throw workingTreeIO(error)
    }
}

private func requireRegularFile(_ path: FilePath) throws(WorkingTreeError) {
    switch lstatPath(path) {
    case let .success(metadata):
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw .unsafePath }
    case let .failure(error):
        throw workingTreeIO(error)
    }
}

func workingTreeIO(_ error: OSIOError) -> WorkingTreeError {
    switch error.errno {
    case ELOOP, ENOTDIR, EISDIR: .unsafePath
    default: .io(message: error.description)
    }
}
