// Rule-based classification of discovered paths by name and extension only. Contents are never
// consulted. Every component of the path is checked, so anything below an excluded directory is
// excluded too. Precedence: secret-like > data > cache > generated > config.
//
// Rules (names compared case-insensitively):
// - secret-like: `.ssh`, `.gnupg`, `.aws`, `.netrc`, `.git-credentials`, `.npmrc`, `.pypirc`,
//   `.docker`, `.kube`, `.password-store`, `.env` / `.env.*`, gh `hosts.yml`, `id_rsa*` /
//   `id_dsa*` / `id_ecdsa*` / `id_ed25519*`, names containing `token`, `secret`, `credential`,
//   `password`, or `passwd`, and extensions `pem`, `key`, `p12`, `pfx`, `gpg`, `asc`, `kdbx`,
//   `keychain`, `keychain-db`. `.npmrc` and `.pypirc` routinely hold registry tokens.
// - data: shell/REPL history (names containing `history`, plus `.lesshst`), `fish_variables`
//   (universal variables fish rewrites itself), `.git` internals, `log`/`logs` directories,
//   extensions `log`, `sqlite`, `sqlite3`, `db`, `db-wal`, `db-shm`, `db-journal`,
//   `sqlite-wal`, `sqlite-shm`, `sqlite-journal`, and `.DS_Store`.
// - cache: `.cache`, names starting or ending with `cache` (`Cache`, `Caches`, `GPUCache`,
//   `Code Cache`), and the `cache` extension.
// - generated: compiled zsh (`*.zwc`), `.zcompdump*`, `__pycache__` / `*.pyc`,
//   `node_modules`, `lazy-lock.json` (rewritten by lazy.nvim on every sync),
//   `packer_compiled.lua`, `*.lock`, and editor swap/backup files (`*.swp`, `*.swo`, `*~`).
// - config: everything else.

import System

/// A path's ``ConfigClass`` and, for excluded classes, a human-readable reason.
public struct ConfigClassification: Sendable, Equatable {
    public var `class`: ConfigClass
    /// Why the path is excluded; `nil` exactly when ``class`` is ``ConfigClass/config``.
    public var reason: String?

    public init(class: ConfigClass, reason: String? = nil) {
        self.class = `class`
        self.reason = reason
    }

    public static let config = ConfigClassification(class: .config)
}

/// Classifies `relativePath` (relative to `$HOME`) by name and extension alone.
///
/// Pure: no filesystem access. See the rules at the top of `ConfigClassifier.swift`.
public func classifyConfigPath(_ relativePath: FilePath) -> ConfigClassification {
    let names = relativePath.components.map { $0.string.lowercased() }
    let rules: [(ConfigClass, (String, [String], Int) -> String?)] = [
        (.secretLike, secretReason),
        (.data, dataReason),
        (.cache, cacheReason),
        (.generated, generatedReason),
    ]
    for (configClass, rule) in rules {
        for (index, name) in names.enumerated() {
            if let reason = rule(name, names, index) {
                return ConfigClassification(class: configClass, reason: reason)
            }
        }
    }
    return .config
}

// MARK: - Rules

private func fileExtension(_ name: String) -> String? {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    let ext = name[name.index(after: dot)...]
    return ext.isEmpty ? nil : String(ext)
}

private let secretNames: Set<String> = [
    ".ssh", ".gnupg", ".aws", ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".docker",
    ".kube", ".password-store", ".env",
]
private let secretSubstrings = ["token", "secret", "credential", "password", "passwd"]
private let secretPrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env."]
private let secretExtensions: Set<String> = [
    "pem", "key", "p12", "pfx", "gpg", "asc", "kdbx", "keychain", "keychain-db",
]

private func secretReason(_ name: String, _ names: [String], _ index: Int) -> String? {
    if secretNames.contains(name) || secretPrefixes.contains(where: name.hasPrefix) {
        return "secret-like: '\(name)' holds credentials or keys"
    }
    if name == "hosts.yml", index > 0, names[index - 1] == "gh" {
        return "secret-like: gh 'hosts.yml' holds OAuth tokens"
    }
    if let word = secretSubstrings.first(where: name.contains) {
        return "secret-like: name contains '\(word)'"
    }
    if let ext = fileExtension(name), secretExtensions.contains(ext) {
        return "secret-like: '.\(ext)' files hold keys or certificates"
    }
    return nil
}

private let dataExtensions: Set<String> = [
    "log", "sqlite", "sqlite3", "db", "db-wal", "db-shm", "db-journal", "sqlite-wal",
    "sqlite-shm", "sqlite-journal", "sqlite3-wal", "sqlite3-shm", "sqlite3-journal",
]

private func dataReason(_ name: String, _ names: [String], _ index: Int) -> String? {
    if name.contains("history") || name == ".lesshst" {
        return "data: command history"
    }
    if name == "fish_variables" {
        return "data: fish universal variables are rewritten by fish"
    }
    if name == ".git" {
        return "data: git repository internals"
    }
    if name == "log" || name == "logs" {
        return "data: log directory"
    }
    if name == ".ds_store" {
        return "data: Finder metadata"
    }
    if let ext = fileExtension(name), dataExtensions.contains(ext) {
        return ext.hasPrefix("log") ? "data: log file" : "data: database file"
    }
    return nil
}

private func cacheReason(_ name: String, _ names: [String], _ index: Int) -> String? {
    if name == ".cache" || name.hasPrefix("cache") || name.hasSuffix("cache") || name.hasSuffix("caches")
        || fileExtension(name) == "cache"
    {
        return "cache: regenerable cache content"
    }
    return nil
}

private let generatedNames: Set<String> = [
    "__pycache__", "node_modules", "lazy-lock.json", "packer_compiled.lua", ".build",
]
private let generatedExtensions: Set<String> = ["zwc", "pyc", "lock", "swp", "swo"]

private func generatedReason(_ name: String, _ names: [String], _ index: Int) -> String? {
    if generatedNames.contains(name) || name.hasPrefix(".zcompdump") || name.hasSuffix("~") {
        return "generated: '\(name)' is written by a tool"
    }
    if let ext = fileExtension(name), generatedExtensions.contains(ext) {
        return "generated: '.\(ext)' files are written by a tool"
    }
    return nil
}
