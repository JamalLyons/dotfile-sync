import System

/// Homebrew package kind. Encodes as `"formula"` / `"cask"`.
public enum PackageKind: String, Codable, Sendable, Hashable, Comparable {
    case formula
    case cask

    /// Declaration order, matching the Rust derived `Ord` (`formula < cask`).
    public static func < (lhs: PackageKind, rhs: PackageKind) -> Bool {
        lhs.order < rhs.order
    }

    private var order: Int {
        switch self {
        case .formula: return 0
        case .cask: return 1
        }
    }
}

/// A package observed on the machine. `version` is omitted from JSON when nil.
public struct ObservedPackage: Codable, Sendable, Equatable {
    public var name: String
    public var kind: PackageKind
    public var version: String?
    public var installed: Bool

    public init(name: String, kind: PackageKind, version: String? = nil, installed: Bool) {
        self.name = name
        self.kind = kind
        self.version = version
        self.installed = installed
    }
}

/// Result of ``discoverHomebrew(_:)``.
///
/// JSON keys are snake_case; `brew_path` and `brew_version` are omitted when nil.
public struct BrewDiscoveryResult: Codable, Sendable, Equatable {
    /// Whether the Homebrew executable was located.
    public var available: Bool
    /// Whether package inventory enumeration succeeded.
    public var packagesEnumerated: Bool
    public var brewPath: FilePath?
    public var brewVersion: String?
    public var formulae: [ObservedPackage]
    public var casks: [ObservedPackage]
    public var diagnostics: [Diagnostic]

    public init(
        available: Bool = false,
        packagesEnumerated: Bool = false,
        brewPath: FilePath? = nil,
        brewVersion: String? = nil,
        formulae: [ObservedPackage] = [],
        casks: [ObservedPackage] = [],
        diagnostics: [Diagnostic] = []
    ) {
        self.available = available
        self.packagesEnumerated = packagesEnumerated
        self.brewPath = brewPath
        self.brewVersion = brewVersion
        self.formulae = formulae
        self.casks = casks
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case available
        case packagesEnumerated = "packages_enumerated"
        case brewPath = "brew_path"
        case brewVersion = "brew_version"
        case formulae
        case casks
        case diagnostics
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decode(Bool.self, forKey: .available)
        packagesEnumerated = try container.decode(Bool.self, forKey: .packagesEnumerated)
        brewPath = try container.decodeIfPresent(String.self, forKey: .brewPath).map { FilePath($0) }
        brewVersion = try container.decodeIfPresent(String.self, forKey: .brewVersion)
        formulae = try container.decode([ObservedPackage].self, forKey: .formulae)
        casks = try container.decode([ObservedPackage].self, forKey: .casks)
        diagnostics = try container.decode([Diagnostic].self, forKey: .diagnostics)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(packagesEnumerated, forKey: .packagesEnumerated)
        // Paths serialize as plain strings, like serde's `PathBuf`.
        try container.encodeIfPresent(brewPath?.string, forKey: .brewPath)
        try container.encodeIfPresent(brewVersion, forKey: .brewVersion)
        try container.encode(formulae, forKey: .formulae)
        try container.encode(casks, forKey: .casks)
        try container.encode(diagnostics, forKey: .diagnostics)
    }
}
