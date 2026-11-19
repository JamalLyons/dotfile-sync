// File-type detection for syntax highlighting, from the path's name and extension only.

import System

/// Highlighting language of a config file. Encodes as a lowercase string.
public enum ConfigLanguage: String, Codable, Sendable, Hashable, CaseIterable {
    case fish
    case toml
    case json
    case yaml
    /// POSIX sh, bash, and zsh, including startup dotfiles such as `.zshrc` and `.bashrc`.
    case shell
    case lua
    /// Git's INI dialect: `~/.gitconfig` and `~/.config/git/config`.
    case gitconfig
    case ini
    case plaintext

    /// Every language detection can return, for documentation.
    public static let supported: [ConfigLanguage] = allCases
}

private let shellDotfiles: Set<String> = [
    ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bashrc", ".bash_profile",
    ".bash_login", ".bash_logout", ".profile", ".kshrc",
]

private let extensionLanguages: [String: ConfigLanguage] = [
    "fish": .fish,
    "toml": .toml,
    "json": .json, "jsonc": .json, "json5": .json,
    "yaml": .yaml, "yml": .yaml,
    "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell,
    "lua": .lua,
    "gitconfig": .gitconfig,
    "ini": .ini, "cfg": .ini,
]

/// Detects the highlighting language of `path` from its file name and extension.
///
/// Pure: no filesystem access. Unknown names are ``ConfigLanguage/plaintext``.
public func detectConfigLanguage(_ path: FilePath) -> ConfigLanguage {
    guard let name = path.lastComponent?.string.lowercased() else { return .plaintext }
    if shellDotfiles.contains(name) {
        return .shell
    }
    if name == ".gitconfig" {
        return .gitconfig
    }
    if name == "config", path.removingLastComponent().lastComponent?.string == "git" {
        return .gitconfig
    }
    if name == ".editorconfig" {
        return .ini
    }
    if let dot = name.lastIndex(of: "."), dot != name.startIndex,
        let language = extensionLanguages[String(name[name.index(after: dot)...])]
    {
        return language
    }
    return .plaintext
}
