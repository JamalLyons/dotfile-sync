// Explicit promotion and demotion of managed files, expressed as an ordinary ``Plan``.
//
// Promote copies a machine file under `$HOME` into the repository and appends a base
// `[[files]]` entry; demote removes a base `[[files]]` entry. Neither ever deletes the machine
// file. Consent rules: every path is classified by name with ``classifyConfigPath(_:)`` before
// anything is read, so secret-like, data, cache and generated files are refused without opening
// them; symlinks are never followed; directories expand to their eligible regular files only.
//
// Source mapping (deterministic): take the target's path relative to `$HOME`; drop a leading
// `.config` component; otherwise strip one leading `.` from the first component. So
// `~/.config/fish/config.fish` → `fish/config.fish`, `~/.gitconfig` → `gitconfig`,
// `~/.local/bin/tool` → `local/bin/tool`.
//
// State fingerprint (see ``manifestChangeFingerprint(_:)``): SHA-256 over the manifest bytes'
// hash, each promote target's content hash and repository source state, and each demote
// target's file type. Hosts recompute it from the stored plan right before apply.

import Darwin
import System

/// What a ``ManifestChangeInput`` asks for. Encodes as `{"op": "promote"|"demote", "targets": [...]}`.
public enum ManifestChange: Codable, Sendable, Equatable {
    /// Enroll these absolute machine paths (files, or directories expanded to their files).
    case promote(targets: [FilePath])
    /// Stop managing these absolute machine paths (base `[[files]]` entries only).
    case demote(targets: [FilePath])

    private enum CodingKeys: String, CodingKey {
        case op, targets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        let targets = try c.decode([String].self, forKey: .targets).map { FilePath($0) }
        switch op {
        case "promote": self = .promote(targets: targets)
        case "demote": self = .demote(targets: targets)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: c, debugDescription: "unknown variant `\(op)`, expected `promote` or `demote`"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .promote(targets):
            try c.encode("promote", forKey: .op)
            try c.encode(targets.map(\.string), forKey: .targets)
        case let .demote(targets):
            try c.encode("demote", forKey: .op)
            try c.encode(targets.map(\.string), forKey: .targets)
        }
    }
}

/// Input for ``planManifestChange(_:hostname:)``.
public struct ManifestChangeInput: Codable, Sendable, Equatable {
    public var manifest: FilePath
    public var home: FilePath
    /// Defaults to the manifest's parent directory, or `.` if it has none.
    public var repoRoot: FilePath?
    /// `nil` selects a profile automatically from `[select]`. Used for exclusions/overrides.
    public var profile: String?
    public var change: ManifestChange

    public init(
        manifest: FilePath,
        home: FilePath,
        repoRoot: FilePath? = nil,
        profile: String? = nil,
        change: ManifestChange
    ) {
        self.manifest = manifest
        self.home = home
        self.repoRoot = repoRoot
        self.profile = profile
        self.change = change
    }

    private enum CodingKeys: String, CodingKey {
        case manifest, home
        case repoRoot = "repo_root"
        case profile, change
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifest = FilePath(try c.decode(String.self, forKey: .manifest))
        home = FilePath(try c.decode(String.self, forKey: .home))
        repoRoot = try c.decodeIfPresent(String.self, forKey: .repoRoot).map { FilePath($0) }
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        change = try c.decode(ManifestChange.self, forKey: .change)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(manifest.string, forKey: .manifest)
        try c.encode(home.string, forKey: .home)
        try c.encode(repoRoot?.string, forKey: .repoRoot)
        try c.encodeIfPresent(profile, forKey: .profile)
        try c.encode(change, forKey: .change)
    }
}

/// Most regular files one directory promotion may enroll.
public let promoteDirectoryFileLimit = 256
/// Deepest directory level one directory promotion descends.
public let promoteDirectoryDepthLimit = 8
/// Largest file promote will copy into the repository.
public let promoteFileSizeLimit: Int64 = 4 * 1024 * 1024

/// Computes a deterministic plan that promotes or demotes managed files.
///
/// Read-only. Throws ``OpError/failed(_:)`` with a specific message for every refusal; nothing
/// is read from a target before its HOME-relative path has been classified as `config`.
public func planManifestChange(
    _ input: ManifestChangeInput,
    hostname: String = currentHostname()
) throws(OpError) -> Plan {
    let manifestBytes: [UInt8]
    do {
        manifestBytes = try readAllBytes(input.manifest)
    } catch {
        throw .manifest(path: input.manifest, source: .io(path: input.manifest.string, reason: "\(error)"))
    }
    let manifest: Manifest
    let resolved: ResolvedManifest
    do throws(ManifestError) {
        guard let text = String(validating: manifestBytes, as: UTF8.self) else {
            throw ManifestError.io(path: input.manifest.string, reason: "stream did not contain valid UTF-8")
        }
        manifest = try parseManifest(text)
        resolved = try resolveProfile(
            manifest, selection: profileSelection(input.profile), hostname: hostname, os: currentOs()
        )
    } catch {
        throw .manifest(path: input.manifest, source: error)
    }
    if case let .success(st) = lstatPath(input.manifest), (st.st_mode & S_IFMT) != S_IFREG {
        throw .failed("manifest '\(input.manifest.string)' is not a regular file; edit it by hand")
    }
    let home = input.home
    let repoRoot = defaultRepoRoot(manifest: input.manifest, repoRoot: input.repoRoot)
    let context = ChangeContext(
        manifestPath: input.manifest, manifest: manifest, resolved: resolved, home: home, repoRoot: repoRoot
    )

    var actions: [ActionKind] = []
    switch input.change {
    case let .promote(targets):
        actions = try planPromotions(targets, context)
    case let .demote(targets):
        actions = try planDemotions(targets, context)
    }
    if actions.isEmpty {
        throw .failed("no targets given")
    }

    var updated = manifest
    for action in actions {
        switch action {
        case let .promoteFile(_, _, _, entrySource, entryTarget, _):
            updated.files.append(TrackedFile(source: entrySource, target: entryTarget))
        case let .demoteFile(target, _, _):
            updated.files.removeAll { rustPathEqual(expandTargetPath($0.target, homeDir: home), target) }
        default:
            break
        }
    }
    // Preflight the exact text edits apply will make, so a manifest layout the editor cannot
    // rewrite fails at plan time rather than after a repository file was written.
    if let text = String(validating: manifestBytes, as: UTF8.self) {
        var edited = text
        for action in actions {
            guard case let .promoteFile(_, _, _, entrySource, entryTarget, _) = action else { continue }
            do {
                edited = try appendingTrackedFile(TrackedFile(source: entrySource, target: entryTarget), to: edited)
            } catch {
                throw .failed("cannot add '\(entryTarget)' to the manifest automatically: \(error); edit it by hand")
            }
        }
    }
    let problems = validateManifest(updated)
    if !problems.isEmpty {
        throw .failed(
            "the changed manifest would be invalid:\n" + problems.map { "- \($0)" }.joined(separator: "\n")
        )
    }

    let planActions = actions.enumerated().map { index, kind in
        PlanAction(
            id: formatActionId(index + 1),
            kind: kind,
            summary: changeSummary(kind),
            risk: .medium,
            reversible: true,
            // The manifest (and an overwritten repository source) is always backed up.
            backup: true
        )
    }
    var plan = Plan(
        schema: PLAN_SCHEMA,
        profile: resolved.profile,
        manifestPath: input.manifest,
        home: home,
        repoRoot: repoRoot,
        actions: planActions,
        stateFingerprint: ""
    )
    plan.stateFingerprint = try manifestChangeFingerprint(plan)
    return plan
}

/// Recomputes the state fingerprint of a plan made by ``planManifestChange(_:hostname:)`` from
/// the current filesystem. A host compares it with ``Plan/stateFingerprint`` before applying;
/// any difference means the manifest, a promote target, or a repository source changed.
///
/// Promote targets are re-classified before they are read and must still be regular files.
public func manifestChangeFingerprint(_ plan: Plan) throws(OpError) -> String {
    var lines: [String] = []
    do {
        lines.append("manifest\t\(plan.manifestPath.string)\tsha:\(sha256Hex(try readAllBytes(plan.manifestPath)))")
    } catch {
        throw .failed("cannot read manifest '\(plan.manifestPath.string)': \(error)")
    }
    for action in plan.actions {
        switch action.kind {
        case let .promoteFile(target, source, _, _, _, _):
            let hash: String
            do {
                hash = try promotableTargetHash(home: plan.home, target: target)
            } catch {
                throw .failed(error.message)
            }
            lines.append("promote\t\(target.string)\tsha:\(hash)")
            lines.append("source\t\(source.string)\t\(sourceToken(source))")
        case let .demoteFile(target, _, _):
            lines.append("demote\t\(target.string)\t\(fileTypeToken(target))")
        default:
            throw .failed("plan action \(action.id) (\(action.kind.tag)) is not a manifest change")
        }
    }
    return sha256Hex(Array(lines.joined(separator: "\n").utf8))
}

/// The deterministic repository source for a HOME-relative target. See the file header.
public func promotedSourcePath(forHomeRelative relative: FilePath) -> FilePath? {
    var names = rustComponents(relative).compactMap { component -> [UInt8]? in
        if case let .normal(name) = component { return name }
        return nil
    }
    guard names.count == rustComponents(relative).count, !names.isEmpty else { return nil }
    if names[0] == Array(".config".utf8) {
        names.removeFirst()
    } else if names[0].first == UInt8(ascii: "."), names[0].count > 1 {
        names[0].removeFirst()
    }
    guard !names.isEmpty else { return nil }
    return filePath(fromBytes: Array(names.joined(separator: [UInt8(ascii: "/")])))
}

// MARK: - Promote

private struct ChangeContext {
    var manifestPath: FilePath
    var manifest: Manifest
    var resolved: ResolvedManifest
    var home: FilePath
    var repoRoot: FilePath

    /// Every target named by a base or profile `[[files]]` entry, expanded.
    var managedTargets: [FilePath] {
        var files = manifest.files
        for name in manifest.profiles.keys.sorted(by: byteOrderPrecedes) {
            files.append(contentsOf: manifest.profiles[name]?.files ?? [])
        }
        return files.map { expandTargetPath($0.target, homeDir: home) }
    }

    var allSources: [FilePath] {
        var files = manifest.files
        for name in manifest.profiles.keys.sorted(by: byteOrderPrecedes) {
            files.append(contentsOf: manifest.profiles[name]?.files ?? [])
        }
        return files.map { decodeManifestPathBytes($0.source) }
    }
}

private func planPromotions(_ targets: [FilePath], _ ctx: ChangeContext) throws(OpError) -> [ActionKind] {
    var files: [FilePath] = []
    for target in targets {
        let relative = try homeRelative(target, ctx)
        try refuseExcludedClass(relative, target)
        switch lstatPath(target) {
        case let .success(st):
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if ctx.managedTargets.contains(where: { rustPathEqual($0, target) }) {
                    throw .failed("'\(target.string)' is already managed by the manifest")
                }
                if isManifestProtected(target, ctx) {
                    throw .failed(
                        "refusing to promote '\(target.string)': it is excluded, a machine override, or local.fish"
                    )
                }
                files.append(target)
            case S_IFDIR:
                if isManifestProtected(target, ctx) {
                    throw .failed("refusing to promote '\(target.string)': it is excluded by the manifest")
                }
                let expanded = try expandDirectory(target, ctx)
                if expanded.isEmpty {
                    throw .failed("'\(target.string)' has no eligible unmanaged config files to promote")
                }
                files.append(contentsOf: expanded)
            case S_IFLNK:
                throw .failed("refusing to promote symlink '\(target.string)'; promote the file it points to")
            default:
                throw .failed("'\(target.string)' is not a regular file or directory")
            }
        case let .failure(error):
            throw .failed("cannot promote '\(target.string)': \(error)")
        }
    }

    var sorted = stableSorted(files, by: rustPathPrecedes)
    sorted = sorted.enumerated().filter { index, path in
        index == 0 || !rustPathEqual(sorted[index - 1], path)
    }.map(\.element)

    let existingSources = ctx.allSources
    var newSources: [FilePath] = []
    var actions: [ActionKind] = []
    for target in sorted {
        let relative = try homeRelative(target, ctx)
        guard let entrySourcePath = promotedSourcePath(forHomeRelative: relative) else {
            throw .failed("cannot derive a repository path for '\(target.string)'")
        }
        if existingSources.contains(where: { rustPathEqual($0, entrySourcePath) }) {
            throw .failed(
                "repository path '\(entrySourcePath.string)' for '\(target.string)' is already the source of another entry"
            )
        }
        if newSources.contains(where: { rustPathEqual($0, entrySourcePath) }) {
            throw .failed("two promoted targets map to the same repository path '\(entrySourcePath.string)'")
        }
        newSources.append(entrySourcePath)
        let source = ctx.repoRoot.pushing(entrySourcePath)
        if rustPathEqual(source, ctx.manifestPath) {
            throw .failed("repository path for '\(target.string)' would overwrite the manifest")
        }
        try checkRepoDestination(source, ctx.repoRoot)
        let hash: String
        do {
            hash = try promotableTargetHash(home: ctx.home, target: target)
        } catch {
            throw .failed(error.message)
        }
        actions.append(.promoteFile(
            target: target,
            source: source,
            manifest: ctx.manifestPath,
            entrySource: encodeManifestPathBytes(entrySourcePath),
            entryTarget: "~/" + encodeManifestPathBytes(relative),
            targetSha256: hash
        ))
    }
    return actions
}

/// Regular files under `directory`, depth-first, sorted by caller. Symlinks are skipped (never
/// followed); excluded names are skipped without descending or reading; managed targets and
/// manifest-excluded/override paths are skipped.
private func expandDirectory(_ directory: FilePath, _ ctx: ChangeContext) throws(OpError) -> [FilePath] {
    var found: [FilePath] = []
    var stack: [(FilePath, Int)] = [(directory, 0)]
    let managed = ctx.managedTargets
    while let (dir, depth) = stack.popLast() {
        let names: [[UInt8]]
        do {
            names = try listDirectory(dir)
        } catch {
            throw .failed("cannot list '\(dir.string)': \(error)")
        }
        for name in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let child = dir.pushing(filePath(fromBytes: name))
            let relative = relativeToHome(home: ctx.home, target: child)
            if classifyConfigPath(relative).class.isExcludedByDefault || isManifestProtected(child, ctx) {
                continue
            }
            guard case let .success(st) = lstatPath(child) else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if managed.contains(where: { rustPathEqual($0, child) }) { continue }
                found.append(child)
                if found.count > promoteDirectoryFileLimit {
                    throw .failed(
                        "'\(directory.string)' holds more than \(promoteDirectoryFileLimit) eligible files; promote smaller folders"
                    )
                }
            case S_IFDIR:
                if depth + 1 >= promoteDirectoryDepthLimit {
                    throw .failed(
                        "'\(directory.string)' is nested deeper than \(promoteDirectoryDepthLimit) levels; promote smaller folders"
                    )
                }
                stack.append((child, depth + 1))
            default:
                continue
            }
        }
    }
    return found
}

/// Manifest exclusions, machine overrides and `local.fish` are never enrolled.
private func isManifestProtected(_ target: FilePath, _ ctx: ChangeContext) -> Bool {
    if rustFileName(target) == Array("local.fish".utf8) {
        return true
    }
    for machineOverride in ctx.resolved.overrides
    where rustPathEqual(expandTargetPath(machineOverride.target, homeDir: ctx.home), target) {
        return true
    }
    for excluded in ctx.resolved.exclusions.paths {
        let path = expandTargetPath(excluded, homeDir: ctx.home)
        if rustPathEqual(path, target) || rustPathStartsWith(target, path) {
            return true
        }
    }
    let targetText = String(decoding: pathBytes(target), as: UTF8.self)
    let fileName = rustFileName(target).map { String(decoding: $0, as: UTF8.self) }
    for pattern in ctx.resolved.exclusions.patterns {
        guard let glob = GlobPattern(pattern) else { continue }
        if glob.matches(targetText) || fileName.map({ glob.matches($0) }) == true {
            return true
        }
    }
    return false
}

private func checkRepoDestination(_ source: FilePath, _ repoRoot: FilePath) throws(OpError) {
    do {
        try checkRepoSource(source, repoRoot: repoRoot)
    } catch {
        throw .failed(error.message)
    }
}

/// `source` must sit strictly inside `repoRoot` with no `.`/`..`; every existing ancestor below
/// `repoRoot` must be a real directory (never a symlink), and an existing `source` must be a
/// regular file (it is backed up, never followed). Run at plan time and again right before apply
/// writes, so a crafted plan or a symlink swapped in after approval cannot redirect the copy.
func checkRepoSource(_ source: FilePath, repoRoot: FilePath) throws(ApplyIOError) {
    let components = rustComponents(source)
    if components.contains(.parentDir) || pathBytes(source).split(separator: UInt8(ascii: "/")).contains([UInt8(ascii: ".")]) {
        throw ApplyIOError("repository path '\(source.string)' must not contain '.' or '..'")
    }
    guard components.count > rustComponents(repoRoot).count, rustPathStartsWith(source, repoRoot) else {
        throw ApplyIOError("repository path '\(source.string)' is not inside '\(repoRoot.string)'")
    }
    let rootCount = rustComponents(repoRoot).count
    var current = source
    var ancestors: [FilePath] = []
    while let parent = rustParent(current), rustComponents(parent).count > rootCount {
        ancestors.append(parent)
        current = parent
    }
    for ancestor in ancestors {
        guard case let .success(st) = lstatPath(ancestor) else { continue }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            throw ApplyIOError("repository path '\(ancestor.string)' exists and is not a directory")
        }
    }
    if case let .success(st) = lstatPath(source), (st.st_mode & S_IFMT) != S_IFREG {
        throw ApplyIOError("repository path '\(source.string)' exists and is not a regular file")
    }
}

// MARK: - Demote

private func planDemotions(_ targets: [FilePath], _ ctx: ChangeContext) throws(OpError) -> [ActionKind] {
    var actions: [ActionKind] = []
    var seen: [FilePath] = []
    for target in stableSorted(targets, by: rustPathPrecedes) {
        if seen.contains(where: { rustPathEqual($0, target) }) { continue }
        seen.append(target)
        _ = try homeRelative(target, ctx)
        guard let entry = ctx.manifest.files.first(where: {
            rustPathEqual(expandTargetPath($0.target, homeDir: ctx.home), target)
        }) else {
            if ctx.managedTargets.contains(where: { rustPathEqual($0, target) }) {
                throw .failed("'\(target.string)' is managed by a profile; edit that profile's [[files]] by hand")
            }
            throw .failed("'\(target.string)' is not managed by the manifest")
        }
        actions.append(.demoteFile(target: target, manifest: ctx.manifestPath, entryTarget: entry.target))
    }
    return actions
}

// MARK: - Shared checks

/// `target` must be absolute, free of `.`/`..`, strictly inside `home`, and reached without
/// passing through a symlinked directory. Returns the HOME-relative path.
private func homeRelative(_ target: FilePath, _ ctx: ChangeContext) throws(OpError) -> FilePath {
    try homeRelativePath(home: ctx.home, target: target).mapError { OpError.failed($0.message) }.get()
}

func homeRelativePath(home: FilePath, target: FilePath) -> Result<FilePath, ApplyIOError> {
    let components = rustComponents(target)
    guard components.first == .rootDir else {
        return .failure(ApplyIOError("target '\(target.string)' must be an absolute path"))
    }
    if components.contains(.parentDir) || pathBytes(target).split(separator: UInt8(ascii: "/")).contains([UInt8(ascii: ".")]) {
        return .failure(ApplyIOError("target '\(target.string)' must not contain '.' or '..'"))
    }
    let homeComponents = rustComponents(home)
    guard components.count > homeComponents.count, rustPathStartsWith(target, home) else {
        return .failure(ApplyIOError("target '\(target.string)' is not inside HOME '\(home.string)'"))
    }
    if let parent = rustParent(target), pathPresent(parent) {
        let realHome = (try? canonicalize(home)) ?? home
        guard let realParent = try? canonicalize(parent), rustPathStartsWith(realParent, realHome) else {
            return .failure(ApplyIOError("target '\(target.string)' resolves outside HOME through a symlink"))
        }
        let expectedTail = homeComponents.count..<(components.count - 1)
        let realTail = rustComponents(realParent).dropFirst(rustComponents(realHome).count)
        if Array(realTail) != Array(components[expectedTail]) {
            return .failure(ApplyIOError("target '\(target.string)' passes through a symlinked directory"))
        }
    }
    return .success(relativeToHome(home: home, target: target))
}

private func refuseExcludedClass(_ relative: FilePath, _ target: FilePath) throws(OpError) {
    let classification = classifyConfigPath(relative)
    if classification.class.isExcludedByDefault {
        throw .failed(
            "refusing to promote '\(target.string)': \(classification.reason ?? classification.class.rawValue)"
        )
    }
}

/// Classifies first, then hashes a promote target opened with `O_NOFOLLOW`. Fails when the
/// target is excluded, not a regular file, outside HOME, or larger than the size limit.
func promotableTargetHash(home: FilePath, target: FilePath) throws(ApplyIOError) -> String {
    try checkPromotable(home: home, target: target)
    return sha256Hex(try readPromoteTarget(target))
}

/// Path-only checks (inside HOME, no symlinked parents, classified `config`). Reads nothing.
func checkPromotable(home: FilePath, target: FilePath) throws(ApplyIOError) {
    let relative = try homeRelativePath(home: home, target: target).get()
    let classification = classifyConfigPath(relative)
    if classification.class.isExcludedByDefault {
        throw ApplyIOError(
            "refusing to read '\(target.string)': \(classification.reason ?? classification.class.rawValue)"
        )
    }
}

/// Reads a regular file without following a final symlink, bounded by ``promoteFileSizeLimit``.
func readPromoteTarget(_ target: FilePath) throws(ApplyIOError) -> [UInt8] {
    let fd = target.withPlatformString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
    if fd < 0 {
        throw ApplyIOError("cannot open '\(target.string)': \(OSIOError.current())")
    }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0 else {
        throw ApplyIOError("cannot stat '\(target.string)': \(OSIOError.current())")
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw ApplyIOError("'\(target.string)' is not a regular file")
    }
    guard Int64(st.st_size) <= promoteFileSizeLimit else {
        throw ApplyIOError("'\(target.string)' is larger than \(promoteFileSizeLimit) bytes")
    }
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            throw ApplyIOError("cannot read '\(target.string)': \(OSIOError.current())")
        }
        if count == 0 { break }
        result.append(contentsOf: buffer[0..<count])
        if Int64(result.count) > promoteFileSizeLimit {
            throw ApplyIOError("'\(target.string)' is larger than \(promoteFileSizeLimit) bytes")
        }
    }
    return result
}

private func sourceToken(_ source: FilePath) -> String {
    guard case let .success(st) = lstatPath(source) else { return "missing" }
    guard (st.st_mode & S_IFMT) == S_IFREG, let bytes = try? readAllBytes(source) else {
        return "type:\(st.st_mode & S_IFMT)"
    }
    return "sha:\(sha256Hex(bytes))"
}

private func fileTypeToken(_ path: FilePath) -> String {
    guard case let .success(st) = lstatPath(path) else { return "missing" }
    return "type:\(st.st_mode & S_IFMT)"
}

/// Names in `directory` (no `.`/`..`).
private func listDirectory(_ directory: FilePath) throws(OSIOError) -> [[UInt8]] {
    guard let dir = directory.withPlatformString({ opendir($0) }) else {
        throw OSIOError.current()
    }
    defer { closedir(dir) }
    var names: [[UInt8]] = []
    while let entry = readdir(dir) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> [UInt8] in
            Array(raw.prefix(Int(entry.pointee.d_namlen)))
        }
        if name == [UInt8(ascii: ".")] || name == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
        names.append(name)
    }
    return names
}

private func changeSummary(_ kind: ActionKind) -> String {
    switch kind {
    case let .promoteFile(target, source, _, _, _, _):
        return "promote \(target.string) -> \(source.string)"
    case let .demoteFile(target, manifest, _):
        return "demote \(target.string) (remove from \(manifest.string))"
    default:
        return kind.tag
    }
}
