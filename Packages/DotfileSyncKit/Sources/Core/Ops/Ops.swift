// Port of crates/dotfilesync-core/src/ops.rs (scan and status; `run_plan` lives with the
// planner port).
//
// Read-only operations shared by every execution host. Hosts supply a ``CommandRunner``, a
// progress callback, and a cancellation check; this module performs no I/O beyond what core
// discovery and inspection already do.

import System

/// Stages reported through the progress callback, in execution order. Encodes as snake_case.
public enum OpStage: String, Codable, Sendable, Hashable {
    case loadingManifest = "loading_manifest"
    case discoveringHomebrew = "discovering_homebrew"
    case inspectingConfigs = "inspecting_configs"
    case comparing
    case planning

    /// Human-readable stage label.
    public var describe: String {
        switch self {
        case .loadingManifest: return "Loading manifest"
        case .discoveringHomebrew: return "Discovering installed Homebrew packages"
        case .inspectingConfigs: return "Inspecting tracked configuration files"
        case .comparing: return "Comparing desired and observed state"
        case .planning: return "Planning changes"
        }
    }
}

/// Failure of a shared operation. `description` matches the Rust `Display` strings.
public enum OpError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The cancellation check returned true.
    case cancelled
    /// The manifest could not be loaded or its profile resolved.
    case manifest(path: FilePath, source: ManifestError)
    /// Any other failure, displayed verbatim.
    case failed(String)

    public var description: String {
        switch self {
        case .cancelled:
            return "operation was cancelled"
        case let .manifest(path, source):
            return "failed to load manifest '\(path.string)': \(source)"
        case let .failed(message):
            return message
        }
    }
}

/// Input for ``runScan(_:runner:progress:isCancelled:)``.
public struct ScanInput: Codable, Sendable, Equatable {
    /// Manifest describing tracked configs. `nil` scans Homebrew only.
    public var manifest: FilePath?
    public var home: FilePath
    /// Defaults to the manifest's parent directory, or `.` if it has none.
    public var repoRoot: FilePath?
    /// `nil` selects a profile automatically (`[select]`, otherwise the base layer).
    public var profile: String?

    public init(manifest: FilePath?, home: FilePath, repoRoot: FilePath? = nil, profile: String? = nil) {
        self.manifest = manifest
        self.home = home
        self.repoRoot = repoRoot
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case manifest, home
        case repoRoot = "repo_root"
        case profile
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try c.decodeIfPresent(String.self, forKey: .manifest).map { FilePath($0) }
        home = FilePath(try c.decode(String.self, forKey: .home))
        repoRoot = try c.decodeIfPresent(String.self, forKey: .repoRoot).map { FilePath($0) }
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // serde writes `None` as `null` unless `skip_serializing_if` is set (only `profile`).
        try c.encode(manifest?.string, forKey: .manifest)
        try c.encode(home.string, forKey: .home)
        try c.encode(repoRoot?.string, forKey: .repoRoot)
        try c.encodeIfPresent(profile, forKey: .profile)
    }
}

/// Input for ``runStatus(_:runner:progress:isCancelled:)``.
public struct StatusInput: Codable, Sendable, Equatable {
    public var manifest: FilePath
    public var home: FilePath
    /// Defaults to the manifest's parent directory, or `.` if it has none.
    public var repoRoot: FilePath?
    /// `nil` selects a profile automatically (`[select]`, otherwise the base layer).
    public var profile: String?

    public init(manifest: FilePath, home: FilePath, repoRoot: FilePath? = nil, profile: String? = nil) {
        self.manifest = manifest
        self.home = home
        self.repoRoot = repoRoot
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case manifest, home
        case repoRoot = "repo_root"
        case profile
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifest = FilePath(try c.decode(String.self, forKey: .manifest))
        home = FilePath(try c.decode(String.self, forKey: .home))
        repoRoot = try c.decodeIfPresent(String.self, forKey: .repoRoot).map { FilePath($0) }
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(manifest.string, forKey: .manifest)
        try c.encode(home.string, forKey: .home)
        try c.encode(repoRoot?.string, forKey: .repoRoot)
        try c.encodeIfPresent(profile, forKey: .profile)
    }
}

/// `repo_root`, else the manifest's non-empty parent, else `.`.
package func defaultRepoRoot(manifest: FilePath, repoRoot: FilePath?) -> FilePath {
    if let repoRoot {
        return repoRoot
    }
    if let parent = rustParent(manifest), !parent.isEmpty {
        return parent
    }
    return FilePath(".")
}

func profileSelection(_ profile: String?) -> ProfileSelection {
    if let profile {
        return .explicit(profile)
    }
    return .auto
}

/// A manifest whose sections are the resolved profile's (Rust `materialized_manifest`).
func materializedManifest(_ original: Manifest, _ resolved: ResolvedManifest) -> Manifest {
    var manifest = Manifest(schemaVersion: original.schemaVersion)
    manifest.metadata = original.metadata
    manifest.packageManagers.homebrew = resolved.homebrew
    manifest.files = resolved.files
    manifest.exclusions = resolved.exclusions
    manifest.overrides = resolved.overrides
    manifest.setup = resolved.setup
    return manifest
}

func checkCancelled(_ isCancelled: () -> Bool) throws(OpError) {
    if isCancelled() {
        throw .cancelled
    }
}

/// Manifest paths are loaded through the String API; non-UTF-8 bytes are lossy here, as in
/// the existing ``loadManifest(_:)-(String)`` port.
private func loadManifest(at path: FilePath) throws(ManifestError) -> Manifest {
    try loadManifest(path.string)
}

/// Discovers Homebrew packages and inspects tracked configs (read-only).
///
/// A manifest that fails to load or resolve is reported as an error diagnostic in the returned
/// report, not thrown. Only cancellation throws.
public func runScan(
    _ input: ScanInput,
    runner: any CommandRunner,
    progress: (OpStage) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
) throws(OpError) -> ScanReport {
    try checkCancelled(isCancelled)
    progress(.discoveringHomebrew)
    let homebrew = discoverHomebrew(runner)
    try checkCancelled(isCancelled)

    var configs: [ObservedConfigFile] = []
    var diagnostics: [Diagnostic] = []

    if let manifestPath = input.manifest {
        progress(.loadingManifest)
        do {
            let manifest = try loadManifest(at: manifestPath)
            try checkCancelled(isCancelled)
            progress(.inspectingConfigs)
            do {
                let resolved = try resolveProfile(
                    manifest,
                    selection: profileSelection(input.profile),
                    hostname: currentHostname(),
                    os: currentOs()
                )
                let inspector = ConfigInspector(
                    repoRoot: defaultRepoRoot(manifest: manifestPath, repoRoot: input.repoRoot),
                    homeDir: input.home,
                    exclusions: resolved.exclusions,
                    overrides: resolved.overrides
                )
                configs = inspector.inspectFiles(resolved.files)
            } catch {
                diagnostics.append(
                    .error("Failed to resolve manifest profile at '\(manifestPath.string)'")
                        .withDetail(error.description)
                )
            }
        } catch let error as ManifestError {
            diagnostics.append(
                .error("Failed to load manifest at '\(manifestPath.string)'")
                    .withDetail(error.description)
            )
        } catch let error as OpError {
            throw error
        } catch {
            throw .failed(String(describing: error))
        }
    } else {
        diagnostics.append(.info(
            "No manifest specified or found; only Homebrew packages were scanned. "
                + "Use --manifest <path> to inspect tracked configs."
        ))
    }

    try checkCancelled(isCancelled)
    return ScanReport(homebrew: homebrew, configs: configs, diagnostics: diagnostics)
}

/// Compares the manifest's desired state with the observed system (read-only).
public func runStatus(
    _ input: StatusInput,
    runner: any CommandRunner,
    progress: (OpStage) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
) throws(OpError) -> StatusReport {
    try checkCancelled(isCancelled)
    progress(.loadingManifest)
    let original: Manifest
    let resolved: ResolvedManifest
    do {
        original = try loadManifest(at: input.manifest)
        resolved = try resolveProfile(
            original,
            selection: profileSelection(input.profile),
            hostname: currentHostname(),
            os: currentOs()
        )
    } catch {
        throw .manifest(path: input.manifest, source: error)
    }
    let manifest = materializedManifest(original, resolved)

    try checkCancelled(isCancelled)
    progress(.discoveringHomebrew)
    let brew = discoverHomebrew(runner)

    try checkCancelled(isCancelled)
    progress(.inspectingConfigs)
    let inspector = ConfigInspector(
        repoRoot: defaultRepoRoot(manifest: input.manifest, repoRoot: input.repoRoot),
        homeDir: input.home,
        exclusions: manifest.exclusions,
        overrides: manifest.overrides
    )
    let configs = inspector.inspectFiles(manifest.files)

    try checkCancelled(isCancelled)
    progress(.comparing)
    let report = compareStatus(manifest, brewResult: brew, configs: configs)
    try checkCancelled(isCancelled)
    return report
}
