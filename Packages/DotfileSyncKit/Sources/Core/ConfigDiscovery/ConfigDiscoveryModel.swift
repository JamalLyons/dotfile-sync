// Output model for bounded, metadata-only config discovery under `$HOME`.
//
// JSON keys are snake_case in declaration order; optional fields are omitted when nil; paths
// encode as strings (non-UTF-8 bytes become U+FFFD), matching the rest of Core's report types.

import System

/// What `lstat` says a discovered path is. Encodes as a lowercase string.
public enum DiscoveredEntryKind: String, Codable, Sendable, Hashable {
    case file
    case directory
    case symlink
    /// A socket, FIFO, device, or anything else that is not a file, directory, or symlink.
    case other
}

/// Rule-based classification of a discovered path. Encodes as a snake_case string.
///
/// Only ``config`` entries are offered for editing; every other class is excluded by default.
public enum ConfigClass: String, Codable, Sendable, Hashable, CaseIterable {
    /// Hand-edited configuration inside a known config location.
    case config
    /// Machine state written by a tool: shell history, databases, logs, VCS internals.
    case data
    /// Regenerable cache content.
    case cache
    /// Tool output that should not be hand-edited: compiled scripts, lockfiles, editor swap files.
    case generated
    /// Credentials, keys, tokens, or a directory that holds them. Never opened or listed.
    case secretLike = "secret_like"

    /// Whether entries of this class are excluded by default (everything except ``config``).
    public var isExcludedByDefault: Bool { self != .config }
}

/// How a tool was detected on this machine. Encodes as a snake_case string.
public enum ToolDetectionSource: String, Codable, Sendable, Hashable, Comparable, CaseIterable {
    /// `$SHELL`'s basename names this tool.
    case shell
    /// A binary with one of the tool's names exists on `PATH` or in a known install directory.
    case binary
    /// One of the tool's application bundles exists in an applications directory.
    case application
    /// At least one of the tool's config locations exists under `$HOME`.
    case configPresent = "config_present"

    public static func < (lhs: ToolDetectionSource, rhs: ToolDetectionSource) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A registry tool found on this machine.
public struct DetectedTool: Codable, Sendable, Equatable {
    /// Stable registry identifier, e.g. `"fish"`.
    public var id: String
    public var name: String
    /// Every signal that detected the tool, in ``ToolDetectionSource`` order.
    public var detectedBy: [ToolDetectionSource]
    /// The tool's registry config locations that exist, sorted by path.
    public var configRoots: [FilePath]

    public init(id: String, name: String, detectedBy: [ToolDetectionSource], configRoots: [FilePath]) {
        self.id = id
        self.name = name
        self.detectedBy = detectedBy
        self.configRoots = configRoots
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case detectedBy = "detected_by"
        case configRoots = "config_roots"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        detectedBy = try c.decode([ToolDetectionSource].self, forKey: .detectedBy)
        configRoots = try c.decode([String].self, forKey: .configRoots).map { FilePath($0) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(detectedBy, forKey: .detectedBy)
        try c.encode(configRoots.map(\.string), forKey: .configRoots)
    }
}

/// One path seen by discovery. Its contents are never read.
public struct DiscoveredEntry: Codable, Sendable, Equatable {
    /// Absolute path.
    public var path: FilePath
    /// Path relative to `$HOME`, e.g. `.config/fish/config.fish`.
    public var relativePath: String
    /// Registry id of the owning tool; `nil` for unrecognized `~/.config` children and
    /// well-known top-level dotfiles that no registry entry claims.
    public var tool: String?
    public var kind: DiscoveredEntryKind
    public var `class`: ConfigClass
    /// Why the entry is excluded; set exactly when ``class`` is not ``ConfigClass/config``.
    public var excludedReason: String?
    /// `lstat` size of a regular file.
    public var sizeBytes: UInt64?
    /// Highlighting language for a `config` file or symlink.
    public var language: ConfigLanguage?
    /// Raw `readlink` destination of a `config` symlink. The link is never followed.
    public var symlinkTarget: FilePath?
    /// Whether ``symlinkTarget`` resolves (lexically) outside `$HOME`.
    public var symlinkOutsideHome: Bool?

    public init(
        path: FilePath,
        relativePath: String,
        tool: String? = nil,
        kind: DiscoveredEntryKind,
        class: ConfigClass,
        excludedReason: String? = nil,
        sizeBytes: UInt64? = nil,
        language: ConfigLanguage? = nil,
        symlinkTarget: FilePath? = nil,
        symlinkOutsideHome: Bool? = nil
    ) {
        self.path = path
        self.relativePath = relativePath
        self.tool = tool
        self.kind = kind
        self.class = `class`
        self.excludedReason = excludedReason
        self.sizeBytes = sizeBytes
        self.language = language
        self.symlinkTarget = symlinkTarget
        self.symlinkOutsideHome = symlinkOutsideHome
    }

    /// Whether the entry is excluded by default.
    public var isExcluded: Bool { self.class.isExcludedByDefault }

    private enum CodingKeys: String, CodingKey {
        case path
        case relativePath = "relative_path"
        case tool
        case kind
        case `class`
        case excludedReason = "excluded_reason"
        case sizeBytes = "size_bytes"
        case language
        case symlinkTarget = "symlink_target"
        case symlinkOutsideHome = "symlink_outside_home"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = FilePath(try c.decode(String.self, forKey: .path))
        relativePath = try c.decode(String.self, forKey: .relativePath)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        kind = try c.decode(DiscoveredEntryKind.self, forKey: .kind)
        self.class = try c.decode(ConfigClass.self, forKey: .class)
        excludedReason = try c.decodeIfPresent(String.self, forKey: .excludedReason)
        sizeBytes = try c.decodeIfPresent(UInt64.self, forKey: .sizeBytes)
        language = try c.decodeIfPresent(ConfigLanguage.self, forKey: .language)
        symlinkTarget = try c.decodeIfPresent(String.self, forKey: .symlinkTarget).map { FilePath($0) }
        symlinkOutsideHome = try c.decodeIfPresent(Bool.self, forKey: .symlinkOutsideHome)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path.string, forKey: .path)
        try c.encode(relativePath, forKey: .relativePath)
        try c.encodeIfPresent(tool, forKey: .tool)
        try c.encode(kind, forKey: .kind)
        try c.encode(self.class, forKey: .class)
        try c.encodeIfPresent(excludedReason, forKey: .excludedReason)
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(symlinkTarget?.string, forKey: .symlinkTarget)
        try c.encodeIfPresent(symlinkOutsideHome, forKey: .symlinkOutsideHome)
    }
}

/// Result of ``discoverConfigs(home:environment:limits:registry:fileSystem:)``.
///
/// `tools` is sorted by id and `entries` by path, so equal machines produce equal reports.
public struct ConfigDiscoveryReport: Codable, Sendable, Equatable {
    public var tools: [DetectedTool]
    public var entries: [DiscoveredEntry]
    /// `true` when a depth or entry limit stopped discovery from seeing everything.
    public var truncated: Bool
    /// Directories that could not be listed, and similar non-fatal problems.
    public var diagnostics: [Diagnostic]

    public init(
        tools: [DetectedTool] = [],
        entries: [DiscoveredEntry] = [],
        truncated: Bool = false,
        diagnostics: [Diagnostic] = []
    ) {
        self.tools = tools
        self.entries = entries
        self.truncated = truncated
        self.diagnostics = diagnostics
    }
}

/// Bounds on discovery work.
public struct ConfigDiscoveryLimits: Sendable, Equatable {
    /// Deepest level reported below a config root (the root itself is depth 0). Directories at
    /// this depth are reported but not listed.
    public var maxDepth: Int
    /// Maximum entries in the report; discovery stops once it is reached.
    public var maxEntries: Int
    /// Maximum names read from a single directory.
    public var maxEntriesPerDirectory: Int

    public init(maxDepth: Int = 8, maxEntries: Int = 5_000, maxEntriesPerDirectory: Int = 1_000) {
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
        self.maxEntriesPerDirectory = maxEntriesPerDirectory
    }

    /// `maxDepth` 8, `maxEntries` 5000, `maxEntriesPerDirectory` 1000.
    public static let `default` = ConfigDiscoveryLimits()
}

/// Process environment discovery depends on, passed in as values so the core never reads
/// `ProcessInfo`.
public struct ConfigDiscoveryEnvironment: Sendable, Equatable {
    /// `$SHELL`, e.g. `/opt/homebrew/bin/fish`.
    public var shell: String?
    /// `$PATH`, colon-separated.
    public var path: String?
    /// Directories searched for tool binaries after `PATH`.
    public var binaryDirectories: [FilePath]
    /// Directories searched for application bundles (`~/Applications` is always searched).
    public var applicationDirectories: [FilePath]

    public init(
        shell: String? = nil,
        path: String? = nil,
        binaryDirectories: [FilePath] = ToolRegistry.binaryDirectories,
        applicationDirectories: [FilePath] = ToolRegistry.applicationDirectories
    ) {
        self.shell = shell
        self.path = path
        self.binaryDirectories = binaryDirectories
        self.applicationDirectories = applicationDirectories
    }

    /// Takes `SHELL` and `PATH` from an environment dictionary, with default search directories.
    public init(environment: [String: String]) {
        self.init(shell: environment["SHELL"], path: environment["PATH"])
    }
}
