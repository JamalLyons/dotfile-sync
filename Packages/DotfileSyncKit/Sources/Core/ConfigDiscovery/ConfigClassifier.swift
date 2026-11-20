// Rule-based classification of discovered paths by name and extension only. Contents are never
// consulted. Every component of the path is checked, so anything below an excluded directory is
// excluded too. Precedence: secret-like > data > cache > generated > unknown > config.
//
// Matching: names are compared case-insensitively. Exact-name rules compare the whole lowercased
// component. Word rules compare *tokens*: a component is split at every non-alphanumeric character
// (`-`, `_`, `.`, space) and at camel-case boundaries (`GPUCache` -> `gpu`, `cache`). A word rule
// never matches inside a longer token, so `cachet`, `mycachetool`, and `tokenizer` match nothing.
//
// Rules:
// - secret-like: exact names `.ssh`, `.gnupg`, `.aws`, `.netrc`, `.git-credentials`, `.npmrc`,
//   `.pypirc`, `.docker`, `.kube`, `.password-store`, `.env`; `.env.*`; gh `hosts.yml`;
//   `id_rsa*` / `id_dsa*` / `id_ecdsa*` / `id_ed25519*`; a token equal to `token(s)`, `secret(s)`,
//   `credential(s)`, `password(s)`, or `passwd` (`api_token`, `credentials.json`, `Secrets`); a
//   component that ends with one of those words with no separator (`apitoken`, `mytokens`); and
//   extensions `pem`, `key`, `p12`, `pfx`, `gpg`, `asc`, `kdbx`, `keychain`, `keychain-db`.
//   `.npmrc` and `.pypirc` routinely hold registry tokens. When in doubt a name is secret.
// - data: shell/REPL history (names containing `history`, plus `.lesshst`), `fish_variables`
//   (universal variables fish rewrites itself), `.git` internals, `log`/`logs` directories,
//   extensions `log`, `sqlite`, `sqlite3`, `db`, `db-wal`, `db-shm`, `db-journal`,
//   `sqlite-wal`, `sqlite-shm`, `sqlite-journal`, and `.DS_Store`.
// - cache: a token equal to `cache` or `caches` (`.cache`, `Cache`, `Caches`, `GPUCache`,
//   `Code Cache`, `node-cache`, `cache_dir`), a separator-free name ending in `cache`/`caches`
//   (`appcache`), and the `cache` extension.
// - generated: compiled zsh (`*.zwc`), `.zcompdump*`, `__pycache__` / `*.pyc`,
//   `node_modules`, `lazy-lock.json` (rewritten by lazy.nvim on every sync),
//   `packer_compiled.lua`, `*.lock`, and editor swap/backup files (`*.swp`, `*.swo`, `*~`).
// - unknown (discovery only, see ``classifyDiscoveredPath(_:)``): a depth-1 child of `~/.config`
//   that no registry tool claims and that no rule above matched. Excluded by default.
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

/// Classifies `relativePath` (relative to `$HOME`) by name, extension, and registry ownership.
///
/// Pure: no filesystem access. See the rules at the top of `ConfigClassifier.swift`.
public func classifyConfigPath(_ relativePath: FilePath) -> ConfigClassification {
    let segments = relativePath.components.map(Segment.init)
    let rules: [(ConfigClass, (Segment, [Segment], Int) -> String?)] = [
        (.secretLike, secretReason),
        (.data, dataReason),
        (.cache, cacheReason),
        (.generated, generatedReason),
    ]
    for (configClass, rule) in rules {
        for (index, segment) in segments.enumerated() {
            if let reason = rule(segment, segments, index) {
                return ConfigClassification(class: configClass, reason: reason)
            }
        }
    }
    return .config
}

/// Classification used by discovery. Same as ``classifyConfigPath(_:)``, except that an
/// unregistered depth-1 child of `~/.config` (`.config/<name>`) that no rule matched becomes
/// ``ConfigClass/unknown`` instead of ``ConfigClass/config``.
///
/// Only discovery uses this. ``classifyConfigPath(_:)`` keeps returning `config` for such paths, so
/// callers that manage hand-listed files are unaffected.
func classifyDiscoveredPath(_ relativePath: FilePath) -> ConfigClassification {
    let classification = classifyConfigPath(relativePath)
    guard classification.class == .config else { return classification }
    let components = relativePath.components.map(\.string)
    guard components.count == 2, components[0] == ToolRegistry.xdgConfigDirectory,
        ToolRegistry.owner(of: relativePath) == nil
    else { return classification }
    return ConfigClassification(
        class: .unknown, reason: "unknown: no registry tool claims this ~/.config entry")
}

// MARK: - Matching

/// One path component: lowercased for exact-name rules, split into word tokens for word rules.
private struct Segment {
    let lower: String
    let tokens: [String]

    init(_ component: FilePath.Component) {
        let raw = component.string
        lower = raw.lowercased()
        tokens = wordTokens(raw)
    }
}

/// Splits `raw` at non-alphanumeric characters and at camel-case boundaries, lowercased.
/// A new word starts at an uppercase letter that follows a lowercase letter or digit, or that
/// ends an acronym run (`GPUCache`: the `C` before `ache` starts a word).
private func wordTokens(_ raw: String) -> [String] {
    let chars = Array(raw)
    var tokens: [String] = []
    var current = ""
    for (index, char) in chars.enumerated() {
        guard char.isLetter || char.isNumber else {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            continue
        }
        if char.isUppercase, !current.isEmpty, startsCamelWord(chars, index) {
            tokens.append(current)
            current = ""
        }
        current += char.lowercased()
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}

private func startsCamelWord(_ chars: [Character], _ index: Int) -> Bool {
    let previous = chars[index - 1]
    if previous.isLowercase || previous.isNumber { return true }
    guard previous.isUppercase, index + 1 < chars.count else { return false }
    return chars[index + 1].isLowercase
}

private func fileExtension(_ name: String) -> String? {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    let ext = name[name.index(after: dot)...]
    return ext.isEmpty ? nil : String(ext)
}

// MARK: - Rules

private let secretNames: Set<String> = [
    ".ssh", ".gnupg", ".aws", ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".docker",
    ".kube", ".password-store", ".env",
]
private let secretPrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env."]
/// Words that mark a component as secret. Matched as a whole token, or as the end of a
/// separator-free name (see ``secretWord(_:)``).
private let secretWords = [
    "token", "tokens", "secret", "secrets", "credential", "credentials", "password", "passwords",
    "passwd",
]
private let secretExtensions: Set<String> = [
    "pem", "key", "p12", "pfx", "gpg", "asc", "kdbx", "keychain", "keychain-db",
]

/// A secret word matches a whole token (`api_token`, `Secrets`) or ends a name with no separator
/// (`apitoken`). It never matches inside a longer word, so `tokenizer` is not secret.
private func secretWord(_ segment: Segment) -> String? {
    if let word = secretWords.first(where: { segment.tokens.contains($0) }) { return word }
    let compact = segment.tokens.joined()
    return secretWords.first { compact.hasSuffix($0) }
}

private func secretReason(_ segment: Segment, _ segments: [Segment], _ index: Int) -> String? {
    let name = segment.lower
    if secretNames.contains(name) || secretPrefixes.contains(where: name.hasPrefix) {
        return "secret-like: '\(name)' holds credentials or keys"
    }
    if name == "hosts.yml", index > 0, segments[index - 1].lower == "gh" {
        return "secret-like: gh 'hosts.yml' holds OAuth tokens"
    }
    if let word = secretWord(segment) {
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

private func dataReason(_ segment: Segment, _ segments: [Segment], _ index: Int) -> String? {
    let name = segment.lower
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

private func cacheReason(_ segment: Segment, _ segments: [Segment], _ index: Int) -> String? {
    // `.cache` is covered by its token `cache`. A separator-free name ending in `cache`
    // (`appcache`) also matches; `cachet` and `mycachetool` do not.
    let isCacheToken = segment.tokens.contains { $0 == "cache" || $0 == "caches" }
    // Raw-name suffix, not joined tokens: `__pycache__` joins to `pycache` but ends in underscores.
    let endsInCache = segment.lower.hasSuffix("cache") || segment.lower.hasSuffix("caches")
    if isCacheToken || endsInCache || fileExtension(segment.lower) == "cache" {
        return "cache: regenerable cache content"
    }
    return nil
}

private let generatedNames: Set<String> = [
    "__pycache__", "node_modules", "lazy-lock.json", "packer_compiled.lua", ".build",
]
private let generatedExtensions: Set<String> = ["zwc", "pyc", "lock", "swp", "swo"]

private func generatedReason(_ segment: Segment, _ segments: [Segment], _ index: Int) -> String? {
    let name = segment.lower
    if generatedNames.contains(name) || name.hasPrefix(".zcompdump") || name.hasSuffix("~") {
        return "generated: '\(name)' is written by a tool"
    }
    if let ext = fileExtension(name), generatedExtensions.contains(ext) {
        return "generated: '.\(ext)' files are written by a tool"
    }
    return nil
}
