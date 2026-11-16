// Port of crates/dotfilesync-core/src/manifest/model.rs.
//
// Coding notes (serde parity):
// - Unknown keys are ignored (serde default; no `deny_unknown_fields`).
// - `#[serde(default)]` fields use `decodeIfPresent` with the Rust default.
// - `skip_serializing_if` fields are omitted when empty / `nil` / default.
// - `Option` fields without `skip_serializing_if` encode `nil` as an explicit null
//   (JSON `null`; TOML has no null, so the TOML encoder drops it, as the `toml` crate does).

/// The only manifest schema this build accepts.
public let CURRENT_SCHEMA_VERSION: UInt32 = 1

/// Operating system a manifest entry can be conditioned on.
///
/// Only macOS is implemented. Other names parse and are then dropped during resolution
/// when they do not match the host ``TargetOs``.
public enum TargetOs: String, Codable, Sendable, Hashable {
    case macos

    /// Lowercase name used in manifests (`"macos"`).
    public var asStr: String { rawValue }

    /// Whether `declared` names this OS, ignoring ASCII case.
    public func matches(_ declared: String) -> Bool {
        asciiLowercased(declared) == rawValue
    }
}

/// How a tracked file is materialized on the machine. Encodes lowercase; defaults to `copy`.
public enum FileMode: String, Codable, Sendable, Hashable {
    case copy
    case symlink

    /// Whether `mode` is ``FileMode/copy`` (the serialization default that is skipped).
    public static func isCopy(_ mode: FileMode) -> Bool {
        mode == .copy
    }
}

/// Optional `[metadata]` table.
public struct ManifestMetadata: Codable, Sendable, Equatable {
    public var name: String?
    public var description: String?

    public init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case name, description
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
    }
}

/// Base `[package_managers.homebrew]` package lists.
public struct HomebrewSection: Codable, Sendable, Equatable {
    public var formulae: [String]
    public var casks: [String]

    public init(formulae: [String] = [], casks: [String] = []) {
        self.formulae = formulae
        self.casks = casks
    }

    private enum CodingKeys: String, CodingKey {
        case formulae, casks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formulae = try c.decodeIfPresent([String].self, forKey: .formulae) ?? []
        casks = try c.decodeIfPresent([String].self, forKey: .casks) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formulae, forKey: .formulae)
        try c.encode(casks, forKey: .casks)
    }
}

/// Package additions and removals contributed by a profile layer.
public struct ProfileHomebrew: Codable, Sendable, Equatable {
    public var formulae: [String]
    public var excludeFormulae: [String]
    public var casks: [String]
    public var excludeCasks: [String]

    public init(
        formulae: [String] = [],
        excludeFormulae: [String] = [],
        casks: [String] = [],
        excludeCasks: [String] = []
    ) {
        self.formulae = formulae
        self.excludeFormulae = excludeFormulae
        self.casks = casks
        self.excludeCasks = excludeCasks
    }

    private enum CodingKeys: String, CodingKey {
        case formulae
        case excludeFormulae = "exclude_formulae"
        case casks
        case excludeCasks = "exclude_casks"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formulae = try c.decodeIfPresent([String].self, forKey: .formulae) ?? []
        excludeFormulae = try c.decodeIfPresent([String].self, forKey: .excludeFormulae) ?? []
        casks = try c.decodeIfPresent([String].self, forKey: .casks) ?? []
        excludeCasks = try c.decodeIfPresent([String].self, forKey: .excludeCasks) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !formulae.isEmpty { try c.encode(formulae, forKey: .formulae) }
        if !excludeFormulae.isEmpty { try c.encode(excludeFormulae, forKey: .excludeFormulae) }
        if !casks.isEmpty { try c.encode(casks, forKey: .casks) }
        if !excludeCasks.isEmpty { try c.encode(excludeCasks, forKey: .excludeCasks) }
    }
}

/// Base `[package_managers]` table.
public struct PackageManagersSection: Codable, Sendable, Equatable {
    public var homebrew: HomebrewSection

    public init(homebrew: HomebrewSection = HomebrewSection()) {
        self.homebrew = homebrew
    }

    private enum CodingKeys: String, CodingKey {
        case homebrew
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homebrew = try c.decodeIfPresent(HomebrewSection.self, forKey: .homebrew) ?? HomebrewSection()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(homebrew, forKey: .homebrew)
    }
}

/// Profile `[profiles.<name>.package_managers]` table.
public struct ProfilePackageManagers: Codable, Sendable, Equatable {
    public var homebrew: ProfileHomebrew

    public init(homebrew: ProfileHomebrew = ProfileHomebrew()) {
        self.homebrew = homebrew
    }

    private enum CodingKeys: String, CodingKey {
        case homebrew
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homebrew = try c.decodeIfPresent(ProfileHomebrew.self, forKey: .homebrew) ?? ProfileHomebrew()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(homebrew, forKey: .homebrew)
    }
}

/// A tracked configuration file entry mapping repository source to machine target.
///
/// Path strings are UTF-8 and may carry percent-encoded bytes (`%HH`) to represent native
/// non-UTF-8 paths; see ``decodeManifestPathBytes(_:)``.
public struct TrackedFile: Codable, Sendable, Equatable {
    /// Relative path within the repository.
    public var source: String
    /// Destination path on the target machine (supports `~` expansion).
    public var target: String
    /// Whether this file is expected to be a machine-local override (not synced).
    public var machineLocal: Bool
    public var description: String?
    /// `copy` (default) writes file bytes; `symlink` points the target at the source.
    public var mode: FileMode
    /// When set, the entry is kept only when it matches the host OS (`macos`).
    public var os: String?

    public init(
        source: String,
        target: String,
        machineLocal: Bool = false,
        description: String? = nil,
        mode: FileMode = .copy,
        os: String? = nil
    ) {
        self.source = source
        self.target = target
        self.machineLocal = machineLocal
        self.description = description
        self.mode = mode
        self.os = os
    }

    private enum CodingKeys: String, CodingKey {
        case source, target
        case machineLocal = "machine_local"
        case description, mode, os
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        target = try c.decode(String.self, forKey: .target)
        machineLocal = try c.decodeIfPresent(Bool.self, forKey: .machineLocal) ?? false
        description = try c.decodeIfPresent(String.self, forKey: .description)
        mode = try c.decodeIfPresent(FileMode.self, forKey: .mode) ?? .copy
        os = try c.decodeIfPresent(String.self, forKey: .os)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(target, forKey: .target)
        try c.encode(machineLocal, forKey: .machineLocal)
        try c.encodeIfPresent(description, forKey: .description)
        if !FileMode.isCopy(mode) { try c.encode(mode, forKey: .mode) }
        try c.encodeIfPresent(os, forKey: .os)
    }
}

/// Scalar setup keys. Absent profile fields do not override an earlier layer.
public struct SetupSection: Codable, Sendable, Equatable {
    public var loginShell: String?
    public var fisher: Bool

    public init(loginShell: String? = nil, fisher: Bool = false) {
        self.loginShell = loginShell
        self.fisher = fisher
    }

    private enum CodingKeys: String, CodingKey {
        case loginShell = "login_shell"
        case fisher
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loginShell = try c.decodeIfPresent(String.self, forKey: .loginShell)
        fisher = try c.decodeIfPresent(Bool.self, forKey: .fisher) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(loginShell, forKey: .loginShell)
        if fisher { try c.encode(fisher, forKey: .fisher) }
    }
}

/// Profile overlay for ``SetupSection``. `nil` means "leave the earlier layer".
public struct SetupOverlay: Codable, Sendable, Equatable {
    public var loginShell: String?
    public var fisher: Bool?

    public init(loginShell: String? = nil, fisher: Bool? = nil) {
        self.loginShell = loginShell
        self.fisher = fisher
    }

    private enum CodingKeys: String, CodingKey {
        case loginShell = "login_shell"
        case fisher
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loginShell = try c.decodeIfPresent(String.self, forKey: .loginShell)
        fisher = try c.decodeIfPresent(Bool.self, forKey: .fisher)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(loginShell, forKey: .loginShell)
        try c.encodeIfPresent(fisher, forKey: .fisher)
    }
}

/// `[exclusions]` table: paths and glob patterns left alone by scan, status, and apply.
public struct ExclusionsSection: Codable, Sendable, Equatable {
    /// Exact file or directory paths to exclude.
    public var paths: [String]
    /// Glob patterns to exclude (e.g. `"*.backup.*"`, `"*token*"`).
    public var patterns: [String]

    public init(paths: [String] = [], patterns: [String] = []) {
        self.paths = paths
        self.patterns = patterns
    }

    private enum CodingKeys: String, CodingKey {
        case paths, patterns
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        patterns = try c.decodeIfPresent([String].self, forKey: .patterns) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paths, forKey: .paths)
        try c.encode(patterns, forKey: .patterns)
    }
}

/// A machine-local target that is never copied or linked over.
public struct MachineOverride: Codable, Sendable, Equatable {
    public var target: String
    public var description: String?

    public init(target: String, description: String? = nil) {
        self.target = target
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case target, description
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

/// Optional hostname → profile mapping.
///
/// Rust uses a `BTreeMap`; code that iterates `hostnames` sorts keys by UTF-8 bytes to match.
public struct SelectSection: Codable, Sendable, Equatable {
    public var hostnames: [String: String]
    public var `default`: String?

    public init(hostnames: [String: String] = [:], default: String? = nil) {
        self.hostnames = hostnames
        self.default = `default`
    }

    private enum CodingKeys: String, CodingKey {
        case hostnames
        case `default`
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostnames = try c.decodeIfPresent([String: String].self, forKey: .hostnames) ?? [:]
        `default` = try c.decodeIfPresent(String.self, forKey: .default)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !hostnames.isEmpty { try c.encode(hostnames, forKey: .hostnames) }
        try c.encodeIfPresent(`default`, forKey: .default)
    }
}

/// One named overlay applied after the base manifest (and after its `extends` chain).
public struct Profile: Codable, Sendable, Equatable {
    public var os: String?
    public var extends: [String]
    public var packageManagers: ProfilePackageManagers
    public var files: [TrackedFile]
    /// Removes a file entry by its manifest target path.
    public var excludeFiles: [String]
    public var setup: SetupOverlay
    public var exclusions: ExclusionsSection
    public var overrides: [MachineOverride]

    public init(
        os: String? = nil,
        extends: [String] = [],
        packageManagers: ProfilePackageManagers = ProfilePackageManagers(),
        files: [TrackedFile] = [],
        excludeFiles: [String] = [],
        setup: SetupOverlay = SetupOverlay(),
        exclusions: ExclusionsSection = ExclusionsSection(),
        overrides: [MachineOverride] = []
    ) {
        self.os = os
        self.extends = extends
        self.packageManagers = packageManagers
        self.files = files
        self.excludeFiles = excludeFiles
        self.setup = setup
        self.exclusions = exclusions
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey {
        case os, extends
        case packageManagers = "package_managers"
        case files
        case excludeFiles = "exclude_files"
        case setup, exclusions, overrides
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        os = try c.decodeIfPresent(String.self, forKey: .os)
        extends = try c.decodeIfPresent([String].self, forKey: .extends) ?? []
        packageManagers =
            try c.decodeIfPresent(ProfilePackageManagers.self, forKey: .packageManagers)
            ?? ProfilePackageManagers()
        files = try c.decodeIfPresent([TrackedFile].self, forKey: .files) ?? []
        excludeFiles = try c.decodeIfPresent([String].self, forKey: .excludeFiles) ?? []
        setup = try c.decodeIfPresent(SetupOverlay.self, forKey: .setup) ?? SetupOverlay()
        exclusions = try c.decodeIfPresent(ExclusionsSection.self, forKey: .exclusions) ?? ExclusionsSection()
        overrides = try c.decodeIfPresent([MachineOverride].self, forKey: .overrides) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(os, forKey: .os)
        if !extends.isEmpty { try c.encode(extends, forKey: .extends) }
        try c.encode(packageManagers, forKey: .packageManagers)
        if !files.isEmpty { try c.encode(files, forKey: .files) }
        if !excludeFiles.isEmpty { try c.encode(excludeFiles, forKey: .excludeFiles) }
        try c.encode(setup, forKey: .setup)
        try c.encode(exclusions, forKey: .exclusions)
        if !overrides.isEmpty { try c.encode(overrides, forKey: .overrides) }
    }
}

/// The parsed `dotfilesync.toml` document.
///
/// `profiles` is a `BTreeMap` in Rust; code that iterates it sorts keys by UTF-8 bytes.
public struct Manifest: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var metadata: ManifestMetadata?
    public var packageManagers: PackageManagersSection
    public var files: [TrackedFile]
    public var exclusions: ExclusionsSection
    public var overrides: [MachineOverride]
    public var select: SelectSection
    public var profiles: [String: Profile]
    public var setup: SetupSection

    /// An otherwise empty manifest with the given schema version (Rust `Manifest::new`).
    public init(schemaVersion: UInt32) {
        self.schemaVersion = schemaVersion
        metadata = nil
        packageManagers = PackageManagersSection()
        files = []
        exclusions = ExclusionsSection()
        overrides = []
        select = SelectSection()
        profiles = [:]
        setup = SetupSection()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case metadata
        case packageManagers = "package_managers"
        case files, exclusions, overrides, select, profiles, setup
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decoded as Int and range-checked: TOMLKit's UInt32 path traps on negative values.
        let rawVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard let version = UInt32(exactly: rawVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: c,
                debugDescription: "invalid value: integer `\(rawVersion)`, expected u32"
            )
        }
        schemaVersion = version
        metadata = try c.decodeIfPresent(ManifestMetadata.self, forKey: .metadata)
        packageManagers =
            try c.decodeIfPresent(PackageManagersSection.self, forKey: .packageManagers)
            ?? PackageManagersSection()
        files = try c.decodeIfPresent([TrackedFile].self, forKey: .files) ?? []
        exclusions = try c.decodeIfPresent(ExclusionsSection.self, forKey: .exclusions) ?? ExclusionsSection()
        overrides = try c.decodeIfPresent([MachineOverride].self, forKey: .overrides) ?? []
        select = try c.decodeIfPresent(SelectSection.self, forKey: .select) ?? SelectSection()
        profiles = try c.decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
        setup = try c.decodeIfPresent(SetupSection.self, forKey: .setup) ?? SetupSection()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encode(packageManagers, forKey: .packageManagers)
        try c.encode(files, forKey: .files)
        try c.encode(exclusions, forKey: .exclusions)
        try c.encode(overrides, forKey: .overrides)
        try c.encode(select, forKey: .select)
        if !profiles.isEmpty { try c.encode(profiles, forKey: .profiles) }
        try c.encode(setup, forKey: .setup)
    }
}

/// ASCII-only lowercase (Rust `to_ascii_lowercase`); non-ASCII scalars are left unchanged.
func asciiLowercased(_ value: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
        if scalar.value >= 0x41, scalar.value <= 0x5A, let lower = Unicode.Scalar(scalar.value + 0x20) {
            scalars.append(lower)
        } else {
            scalars.append(scalar)
        }
    }
    return String(scalars)
}

/// Rust `String` ordering: lexicographic by UTF-8 bytes.
func byteOrderPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
