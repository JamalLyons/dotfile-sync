// Port of crates/dotfilesync-core/src/comparison/model.rs.

import System

/// How desired and observed state relate. Encodes as a snake_case string; `Comparable` follows
/// declaration order like the Rust derived `Ord`.
public enum DifferenceClassification: String, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case matching
    case missing
    case changed
    case unmanaged
    case unknown
    case skipped

    public static func < (lhs: DifferenceClassification, rhs: DifferenceClassification) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// One Homebrew package's desired-vs-observed comparison.
public struct PackageDifference: Codable, Sendable, Equatable {
    public var name: String
    public var kind: PackageKind
    public var classification: DifferenceClassification
    /// Declared in the manifest.
    public var desired: Bool
    /// `nil` when Homebrew state is unknown.
    public var installed: Bool?
    public var observedVersion: String?
    public var diagnostic: String?

    public init(
        name: String,
        kind: PackageKind,
        classification: DifferenceClassification,
        desired: Bool,
        installed: Bool? = nil,
        observedVersion: String? = nil,
        diagnostic: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.classification = classification
        self.desired = desired
        self.installed = installed
        self.observedVersion = observedVersion
        self.diagnostic = diagnostic
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, classification, desired, installed
        case observedVersion = "observed_version"
        case diagnostic
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(PackageKind.self, forKey: .kind)
        classification = try c.decode(DifferenceClassification.self, forKey: .classification)
        desired = try c.decode(Bool.self, forKey: .desired)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed)
        observedVersion = try c.decodeIfPresent(String.self, forKey: .observedVersion)
        diagnostic = try c.decodeIfPresent(String.self, forKey: .diagnostic)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(classification, forKey: .classification)
        try c.encode(desired, forKey: .desired)
        try c.encodeIfPresent(installed, forKey: .installed)
        try c.encodeIfPresent(observedVersion, forKey: .observedVersion)
        try c.encodeIfPresent(diagnostic, forKey: .diagnostic)
    }
}

/// One tracked config file's desired-vs-observed comparison.
public struct ConfigDifference: Codable, Sendable, Equatable {
    public var source: FilePath
    public var target: FilePath
    public var classification: DifferenceClassification
    public var state: ConfigFileState
    public var sourceHash: String?
    public var targetHash: String?
    public var diagnostic: String?

    public init(
        source: FilePath,
        target: FilePath,
        classification: DifferenceClassification,
        state: ConfigFileState,
        sourceHash: String? = nil,
        targetHash: String? = nil,
        diagnostic: String? = nil
    ) {
        self.source = source
        self.target = target
        self.classification = classification
        self.state = state
        self.sourceHash = sourceHash
        self.targetHash = targetHash
        self.diagnostic = diagnostic
    }

    private enum CodingKeys: String, CodingKey {
        case source, target, classification, state
        case sourceHash = "source_hash"
        case targetHash = "target_hash"
        case diagnostic
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = FilePath(try c.decode(String.self, forKey: .source))
        target = FilePath(try c.decode(String.self, forKey: .target))
        classification = try c.decode(DifferenceClassification.self, forKey: .classification)
        state = try c.decode(ConfigFileState.self, forKey: .state)
        sourceHash = try c.decodeIfPresent(String.self, forKey: .sourceHash)
        targetHash = try c.decodeIfPresent(String.self, forKey: .targetHash)
        diagnostic = try c.decodeIfPresent(String.self, forKey: .diagnostic)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source.string, forKey: .source)
        try c.encode(target.string, forKey: .target)
        try c.encode(classification, forKey: .classification)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(sourceHash, forKey: .sourceHash)
        try c.encodeIfPresent(targetHash, forKey: .targetHash)
        try c.encodeIfPresent(diagnostic, forKey: .diagnostic)
    }
}

/// Counts per classification. Rust `usize` fields map to `Int`.
public struct StatusSummary: Codable, Sendable, Equatable {
    public var packagesMatching: Int
    public var packagesMissing: Int
    public var packagesUnmanaged: Int
    public var packagesUnknown: Int
    public var configsMatching: Int
    public var configsChanged: Int
    public var configsMissing: Int
    public var configsUnknown: Int
    public var configsSkipped: Int

    public init(
        packagesMatching: Int = 0,
        packagesMissing: Int = 0,
        packagesUnmanaged: Int = 0,
        packagesUnknown: Int = 0,
        configsMatching: Int = 0,
        configsChanged: Int = 0,
        configsMissing: Int = 0,
        configsUnknown: Int = 0,
        configsSkipped: Int = 0
    ) {
        self.packagesMatching = packagesMatching
        self.packagesMissing = packagesMissing
        self.packagesUnmanaged = packagesUnmanaged
        self.packagesUnknown = packagesUnknown
        self.configsMatching = configsMatching
        self.configsChanged = configsChanged
        self.configsMissing = configsMissing
        self.configsUnknown = configsUnknown
        self.configsSkipped = configsSkipped
    }

    private enum CodingKeys: String, CodingKey {
        case packagesMatching = "packages_matching"
        case packagesMissing = "packages_missing"
        case packagesUnmanaged = "packages_unmanaged"
        case packagesUnknown = "packages_unknown"
        case configsMatching = "configs_matching"
        case configsChanged = "configs_changed"
        case configsMissing = "configs_missing"
        case configsUnknown = "configs_unknown"
        case configsSkipped = "configs_skipped"
    }
}

/// Output of ``compareStatus(_:brewResult:configs:)``.
public struct StatusReport: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var homebrewAvailable: Bool
    public var brewVersion: String?
    public var packageDifferences: [PackageDifference]
    public var configDifferences: [ConfigDifference]
    public var diagnostics: [Diagnostic]
    public var summary: StatusSummary

    public init(
        schemaVersion: UInt32,
        homebrewAvailable: Bool,
        brewVersion: String? = nil,
        packageDifferences: [PackageDifference] = [],
        configDifferences: [ConfigDifference] = [],
        diagnostics: [Diagnostic] = [],
        summary: StatusSummary = StatusSummary()
    ) {
        self.schemaVersion = schemaVersion
        self.homebrewAvailable = homebrewAvailable
        self.brewVersion = brewVersion
        self.packageDifferences = packageDifferences
        self.configDifferences = configDifferences
        self.diagnostics = diagnostics
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case homebrewAvailable = "homebrew_available"
        case brewVersion = "brew_version"
        case packageDifferences = "package_differences"
        case configDifferences = "config_differences"
        case diagnostics, summary
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(UInt32.self, forKey: .schemaVersion)
        homebrewAvailable = try c.decode(Bool.self, forKey: .homebrewAvailable)
        brewVersion = try c.decodeIfPresent(String.self, forKey: .brewVersion)
        packageDifferences = try c.decode([PackageDifference].self, forKey: .packageDifferences)
        configDifferences = try c.decode([ConfigDifference].self, forKey: .configDifferences)
        diagnostics = try c.decode([Diagnostic].self, forKey: .diagnostics)
        summary = try c.decode(StatusSummary.self, forKey: .summary)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(homebrewAvailable, forKey: .homebrewAvailable)
        try c.encodeIfPresent(brewVersion, forKey: .brewVersion)
        try c.encode(packageDifferences, forKey: .packageDifferences)
        try c.encode(configDifferences, forKey: .configDifferences)
        try c.encode(diagnostics, forKey: .diagnostics)
        try c.encode(summary, forKey: .summary)
    }
}
