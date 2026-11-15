// Port of crates/dotfilesync-core/src/plan/model.rs.
//
// Desired-state plan. The plan body is deterministic: no clocks and no random ids.
// JSON matches serde: keys in declaration order, `ActionKind` internally tagged by `kind`
// (snake_case), `Option` fields written as `null` except `PlanInput.profile` (skipped when nil).

import CryptoKit
import Foundation
import System

/// Schema version written into every ``Plan``.
public let PLAN_SCHEMA: UInt32 = 1

/// Risk class assigned by the planner. Encodes as a snake_case string.
public enum Risk: String, Codable, Sendable, Hashable {
    case low
    case medium
    case high
}

/// Typed action. The executor maps each variant to a fixed command or filesystem operation.
///
/// Encodes like serde `#[serde(tag = "kind", rename_all = "snake_case")]`: the `kind` key
/// first, then the variant's fields in declaration order.
public enum ActionKind: Codable, Sendable, Equatable {
    case brewInstallFormula(name: String)
    case brewInstallCask(name: String)
    case linkFile(source: FilePath, target: FilePath)
    case copyFile(source: FilePath, target: FilePath)
    case ensureLocalOverride(target: FilePath, template: FilePath?)
    case installFisher
    case fisherUpdate
    case setLoginShell(shell: FilePath)

    /// The serde tag value for this variant.
    public var tag: String {
        switch self {
        case .brewInstallFormula: return "brew_install_formula"
        case .brewInstallCask: return "brew_install_cask"
        case .linkFile: return "link_file"
        case .copyFile: return "copy_file"
        case .ensureLocalOverride: return "ensure_local_override"
        case .installFisher: return "install_fisher"
        case .fisherUpdate: return "fisher_update"
        case .setLoginShell: return "set_login_shell"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, name, source, target, template, shell
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        func path(_ key: CodingKeys) throws -> FilePath {
            FilePath(try c.decode(String.self, forKey: key))
        }
        switch kind {
        case "brew_install_formula":
            self = .brewInstallFormula(name: try c.decode(String.self, forKey: .name))
        case "brew_install_cask":
            self = .brewInstallCask(name: try c.decode(String.self, forKey: .name))
        case "link_file":
            self = .linkFile(source: try path(.source), target: try path(.target))
        case "copy_file":
            self = .copyFile(source: try path(.source), target: try path(.target))
        case "ensure_local_override":
            self = .ensureLocalOverride(
                target: try path(.target),
                template: try c.decodeIfPresent(String.self, forKey: .template).map { FilePath($0) }
            )
        case "install_fisher":
            self = .installFisher
        case "fisher_update":
            self = .fisherUpdate
        case "set_login_shell":
            self = .setLoginShell(shell: try path(.shell))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown variant `\(kind)`"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tag, forKey: .kind)
        switch self {
        case let .brewInstallFormula(name), let .brewInstallCask(name):
            try c.encode(name, forKey: .name)
        case let .linkFile(source, target), let .copyFile(source, target):
            try c.encode(source.string, forKey: .source)
            try c.encode(target.string, forKey: .target)
        case let .ensureLocalOverride(target, template):
            try c.encode(target.string, forKey: .target)
            try c.encode(template?.string, forKey: .template)
        case .installFisher, .fisherUpdate:
            break
        case let .setLoginShell(shell):
            try c.encode(shell.string, forKey: .shell)
        }
    }
}

/// One planned step.
public struct PlanAction: Codable, Sendable, Equatable {
    /// Stable index within this plan, `a-001` upward.
    public var id: String
    public var kind: ActionKind
    public var summary: String
    public var risk: Risk
    public var reversible: Bool
    /// The target exists and differs, so apply will back it up before replacing it.
    public var backup: Bool

    public init(id: String, kind: ActionKind, summary: String, risk: Risk, reversible: Bool, backup: Bool) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.risk = risk
        self.reversible = reversible
        self.backup = backup
    }
}

/// A deterministic desired-state plan.
public struct Plan: Codable, Sendable, Equatable {
    public var schema: UInt32
    public var profile: String?
    public var manifestPath: FilePath
    public var home: FilePath
    public var repoRoot: FilePath
    public var actions: [PlanAction]
    /// SHA-256 of the observed state the plan was computed from.
    public var stateFingerprint: String

    public init(
        schema: UInt32,
        profile: String?,
        manifestPath: FilePath,
        home: FilePath,
        repoRoot: FilePath,
        actions: [PlanAction],
        stateFingerprint: String
    ) {
        self.schema = schema
        self.profile = profile
        self.manifestPath = manifestPath
        self.home = home
        self.repoRoot = repoRoot
        self.actions = actions
        self.stateFingerprint = stateFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case schema, profile
        case manifestPath = "manifest_path"
        case home
        case repoRoot = "repo_root"
        case actions
        case stateFingerprint = "state_fingerprint"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(UInt32.self, forKey: .schema)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        manifestPath = FilePath(try c.decode(String.self, forKey: .manifestPath))
        home = FilePath(try c.decode(String.self, forKey: .home))
        repoRoot = FilePath(try c.decode(String.self, forKey: .repoRoot))
        actions = try c.decode([PlanAction].self, forKey: .actions)
        stateFingerprint = try c.decode(String.self, forKey: .stateFingerprint)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(profile, forKey: .profile)
        try c.encode(manifestPath.string, forKey: .manifestPath)
        try c.encode(home.string, forKey: .home)
        try c.encode(repoRoot.string, forKey: .repoRoot)
        try c.encode(actions, forKey: .actions)
        try c.encode(stateFingerprint, forKey: .stateFingerprint)
    }

    /// SHA-256 (lowercase hex) of the canonical compact JSON encoding of this plan
    /// (`serde_json::to_vec`). An encoding failure hashes empty bytes, like Rust's
    /// `unwrap_or_default`.
    public var digest: String {
        let json = (try? jsonStringCompact(self)) ?? ""
        return sha256Hex(Array(json.utf8))
    }

    /// `p-` plus the first 16 hex characters of ``digest``.
    public var planId: String {
        "p-" + digest.prefix(16)
    }

    /// True when the plan has no actions.
    public var isEmpty: Bool {
        actions.isEmpty
    }
}

/// Input for ``runPlan(_:runner:hostname:progress:isCancelled:)``.
public struct PlanInput: Codable, Sendable, Equatable {
    public var manifest: FilePath
    public var home: FilePath
    public var repoRoot: FilePath?
    /// `nil` selects a profile automatically from `[select]`.
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

/// Lowercase hex SHA-256 of `bytes`.
func sha256Hex(_ bytes: [UInt8]) -> String {
    hexEncode(Array(SHA256.hash(data: bytes)))
}

/// Lowercase hex encoding (Rust `hex::encode`).
func hexEncode(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}
