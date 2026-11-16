// Port of crates/dotfilesync-core/src/scan/model.rs.

/// Output of ``runScan(_:runner:progress:isCancelled:)``: raw Homebrew discovery plus
/// inspected configs.
public struct ScanReport: Codable, Sendable, Equatable {
    public var homebrew: BrewDiscoveryResult
    public var configs: [ObservedConfigFile]
    public var diagnostics: [Diagnostic]

    public init(homebrew: BrewDiscoveryResult, configs: [ObservedConfigFile], diagnostics: [Diagnostic]) {
        self.homebrew = homebrew
        self.configs = configs
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case homebrew, configs, diagnostics
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(homebrew, forKey: .homebrew)
        try c.encode(configs, forKey: .configs)
        try c.encode(diagnostics, forKey: .diagnostics)
    }
}
