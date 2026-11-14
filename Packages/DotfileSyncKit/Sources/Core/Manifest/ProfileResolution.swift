// Port of crates/dotfilesync-core/src/manifest/profile.rs.
//
// Merge order is base, then each `extends` profile depth-first in listed order, then the
// selected profile. Within a layer, package names are added and then `exclude_*` removes them
// (an exclude wins over an add from an earlier layer; a later layer can add the name again).
// Files are keyed by manifest target path: a later layer replaces the earlier entry wholesale,
// and `exclude_files` removes by that same target. Scalar `setup` keys use last-layer-wins when
// the key is present. Exclusions and overrides are unioned. Lists are sorted (UTF-8 byte order,
// as Rust `BTreeSet`/`BTreeMap`) and deduplicated. Entries whose `os` does not match the
// requested ``TargetOs`` are dropped. A cycle in `extends` is an error.

import Darwin

/// How a caller chooses which profile to resolve.
public enum ProfileSelection: Sendable, Equatable {
    /// `select.hostnames[hostname]`, else `select.default`, else the base layer only.
    case auto
    /// A named profile. It must exist.
    case explicit(String)
    /// Ignore `select` and every profile.
    case baseOnly
}

/// The manifest after profile selection, OS filtering, and layer merge.
public struct ResolvedManifest: Sendable, Equatable {
    public var profile: String?
    public var os: TargetOs
    public var homebrew: HomebrewSection
    public var files: [TrackedFile]
    public var setup: SetupSection
    public var exclusions: ExclusionsSection
    public var overrides: [MachineOverride]

    public init(
        profile: String?,
        os: TargetOs,
        homebrew: HomebrewSection,
        files: [TrackedFile],
        setup: SetupSection,
        exclusions: ExclusionsSection,
        overrides: [MachineOverride]
    ) {
        self.profile = profile
        self.os = os
        self.homebrew = homebrew
        self.files = files
        self.setup = setup
        self.exclusions = exclusions
        self.overrides = overrides
    }
}

/// Hostname from `gethostname`, with a trailing `.local` removed and ASCII lowercased.
public func currentHostname() -> String {
    normalizeHostname(rawHostname())
}

/// The only implemented target OS.
public func currentOs() -> TargetOs {
    .macos
}

/// Trims whitespace, ASCII-lowercases, and strips one trailing `.local`.
public func normalizeHostname(_ raw: String) -> String {
    let trimmed = asciiLowercased(rustTrim(raw))
    if trimmed.hasSuffix(".local") {
        return String(trimmed.dropLast(".local".count))
    }
    return trimmed
}

private func rawHostname() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
        guard let base = ptr.baseAddress else { return -1 }
        return gethostname(base, ptr.count)
    }
    guard rc == 0 else { return "" }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Profile-related validation problems (Rust `profile_validation_errors`).
func profileValidationErrors(_ manifest: Manifest) -> [ValidationError] {
    var errors: [ValidationError] = []
    let profileNames = manifest.profiles.keys.sorted(by: byteOrderPrecedes)

    for name in profileNames {
        guard let profile = manifest.profiles[name] else { continue }
        if name.isEmpty {
            errors.append(.unknownProfile(name: name, context: "profiles"))
        }
        if let os = profile.os, rustTrim(os).isEmpty {
            errors.append(.invalidOsCondition(value: os))
        }
        for extended in profile.extends where manifest.profiles[extended] == nil {
            errors.append(.unknownProfile(name: extended, context: "profiles.\(name).extends"))
        }
    }

    for host in manifest.select.hostnames.keys.sorted(by: byteOrderPrecedes) {
        guard let profile = manifest.select.hostnames[host] else { continue }
        if manifest.profiles[profile] == nil {
            errors.append(.unknownProfile(name: profile, context: "select.hostnames.\(host)"))
        }
    }
    if let fallback = manifest.select.default, manifest.profiles[fallback] == nil {
        errors.append(.unknownProfile(name: fallback, context: "select.default"))
    }

    if case let .failure(.profileCycle(cycle)) = extendOrder(manifest, roots: profileNames) {
        errors.append(.profileCycle(cycle: cycle))
    }

    return errors
}

/// Resolves `selection` against `manifest` for `hostname` and `os`.
public func resolveProfile(
    _ manifest: Manifest,
    selection: ProfileSelection,
    hostname: String,
    os: TargetOs
) throws(ManifestError) -> ResolvedManifest {
    let profileName = try selectName(manifest, selection: selection, hostname: hostname)
    let order: [String]
    if let profileName {
        order = try extendOrder(manifest, roots: [profileName]).get()
    } else {
        order = []
    }

    var formulae = Set(manifest.packageManagers.homebrew.formulae)
    var casks = Set(manifest.packageManagers.homebrew.casks)

    var files: [String: TrackedFile] = [:]
    for file in manifest.files where osMatches(file.os, os) {
        files[file.target] = file
    }

    var setup = manifest.setup
    var exclusionPaths = Set(manifest.exclusions.paths)
    var exclusionPatterns = Set(manifest.exclusions.patterns)
    var overrides: [String: MachineOverride] = [:]
    for override in manifest.overrides {
        overrides[override.target] = override
    }

    for name in order {
        guard let profile = manifest.profiles[name] else {
            throw .unknownProfile(name: name)
        }
        guard osMatches(profile.os, os) else { continue }

        let brew = profile.packageManagers.homebrew
        formulae.formUnion(brew.formulae)
        casks.formUnion(brew.casks)
        formulae.subtract(brew.excludeFormulae)
        casks.subtract(brew.excludeCasks)

        for file in profile.files where osMatches(file.os, os) {
            files[file.target] = file
        }
        for target in profile.excludeFiles {
            files.removeValue(forKey: target)
        }

        if let shell = profile.setup.loginShell {
            setup.loginShell = shell
        }
        if let fisher = profile.setup.fisher {
            setup.fisher = fisher
        }

        exclusionPaths.formUnion(profile.exclusions.paths)
        exclusionPatterns.formUnion(profile.exclusions.patterns)
        for override in profile.overrides {
            overrides[override.target] = override
        }
    }

    return ResolvedManifest(
        profile: profileName,
        os: os,
        homebrew: HomebrewSection(
            formulae: formulae.sorted(by: byteOrderPrecedes),
            casks: casks.sorted(by: byteOrderPrecedes)
        ),
        files: sortedValues(files),
        setup: setup,
        exclusions: ExclusionsSection(
            paths: exclusionPaths.sorted(by: byteOrderPrecedes),
            patterns: exclusionPatterns.sorted(by: byteOrderPrecedes)
        ),
        overrides: sortedValues(overrides)
    )
}

private func sortedValues<V>(_ map: [String: V]) -> [V] {
    map.keys.sorted(by: byteOrderPrecedes).compactMap { map[$0] }
}

private func osMatches(_ declared: String?, _ os: TargetOs) -> Bool {
    guard let declared else { return true }
    return os.matches(declared)
}

private func selectName(
    _ manifest: Manifest,
    selection: ProfileSelection,
    hostname: String
) throws(ManifestError) -> String? {
    switch selection {
    case .baseOnly:
        return nil
    case let .explicit(name):
        guard manifest.profiles[name] != nil else {
            throw .unknownProfile(name: name)
        }
        return name
    case .auto:
        let host = normalizeHostname(hostname)
        // First match in key order, as Rust iterates its BTreeMap.
        let mappedKey = manifest.select.hostnames.keys
            .sorted(by: byteOrderPrecedes)
            .first { normalizeHostname($0) == host }
        let mapped = mappedKey.flatMap { manifest.select.hostnames[$0] } ?? manifest.select.default
        guard let name = mapped else { return nil }
        guard manifest.profiles[name] != nil else {
            throw .unknownProfile(name: name)
        }
        return name
    }
}

/// Depth-first `extends` order, each profile emitted after the profiles it extends.
private func extendOrder(_ manifest: Manifest, roots: [String]) -> Result<[String], ManifestError> {
    var walker = ExtendWalker(manifest: manifest)
    do {
        for root in roots {
            try walker.walk(root)
        }
    } catch {
        return .failure(error)
    }
    return .success(walker.order)
}

private struct ExtendWalker {
    let manifest: Manifest
    var visiting: [String] = []
    var done: Set<String> = []
    var order: [String] = []

    init(manifest: Manifest) {
        self.manifest = manifest
    }

    mutating func walk(_ name: String) throws(ManifestError) {
        if done.contains(name) {
            return
        }
        if visiting.contains(name) {
            throw .profileCycle(cycle: (visiting + [name]).joined(separator: " -> "))
        }
        guard let profile = manifest.profiles[name] else {
            throw .unknownProfile(name: name)
        }
        visiting.append(name)
        for extended in profile.extends {
            try walk(extended)
        }
        visiting.removeLast()
        done.insert(name)
        order.append(name)
    }
}
