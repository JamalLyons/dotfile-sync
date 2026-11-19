// Static, data-only registry of tools whose configuration discovery knows how to find.
//
// Discovery only enumerates the config paths listed here (plus the depth-1 children of
// `~/.config` and ``ToolRegistry/wellKnownHomeEntries``); it never scans `$HOME` recursively.
// Secret-holding locations such as `~/.ssh` deliberately have no registry entry.

import System

/// One known tool: how to detect it and where its configuration lives.
public struct ToolProfile: Sendable, Equatable {
    /// Stable identifier, e.g. `"fish"`.
    public var id: String
    /// Human-readable name, e.g. `"Fish"`.
    public var name: String
    /// Executable names looked up on `PATH` and in ``ToolRegistry/binaryDirectories``.
    public var binaries: [String]
    /// `$SHELL` basenames that identify this tool as the login shell.
    public var shellNames: [String]
    /// Application bundle names (e.g. `"Ghostty.app"`) looked up in application directories.
    public var applications: [String]
    /// Config locations relative to `$HOME`. Files and directories are both allowed; selected
    /// `Library/Application Support` profiles appear here and nowhere else.
    public var configPaths: [String]

    public init(
        id: String,
        name: String,
        binaries: [String] = [],
        shellNames: [String] = [],
        applications: [String] = [],
        configPaths: [String]
    ) {
        self.id = id
        self.name = name
        self.binaries = binaries
        self.shellNames = shellNames
        self.applications = applications
        self.configPaths = configPaths
    }
}

/// The built-in tool registry and the fixed search locations discovery uses.
public enum ToolRegistry {
    /// Built-in tools, sorted by id.
    public static let tools: [ToolProfile] = [
        ToolProfile(
            id: "bash", name: "Bash", binaries: ["bash"], shellNames: ["bash"],
            configPaths: [".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile"]),
        ToolProfile(
            id: "fish", name: "Fish", binaries: ["fish"], shellNames: ["fish"],
            configPaths: [".config/fish"]),
        ToolProfile(
            id: "ghostty", name: "Ghostty", binaries: ["ghostty"], applications: ["Ghostty.app"],
            configPaths: [".config/ghostty", "Library/Application Support/com.mitchellh.ghostty"]),
        ToolProfile(
            id: "git", name: "Git", binaries: ["git"],
            configPaths: [".gitconfig", ".config/git"]),
        ToolProfile(
            id: "nvim", name: "Neovim", binaries: ["nvim"],
            configPaths: [".config/nvim"]),
        ToolProfile(
            id: "starship", name: "Starship", binaries: ["starship"],
            configPaths: [".config/starship.toml"]),
        ToolProfile(
            id: "tmux", name: "tmux", binaries: ["tmux"],
            configPaths: [".tmux.conf", ".config/tmux"]),
        ToolProfile(
            id: "zed", name: "Zed", binaries: ["zed"], applications: ["Zed.app"],
            configPaths: [".config/zed"]),
        ToolProfile(
            id: "zsh", name: "Zsh", binaries: ["zsh"], shellNames: ["zsh"],
            configPaths: [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".config/zsh"]),
    ]

    /// Directories searched for tool binaries after the entries of `PATH`.
    public static let binaryDirectories: [FilePath] = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    ]

    /// Directories searched for application bundles, in addition to `~/Applications`.
    public static let applicationDirectories: [FilePath] = ["/Applications"]

    /// The XDG config directory, relative to `$HOME`. Its immediate children are reported
    /// (metadata only) so tools without a registry entry still surface as candidates.
    public static let xdgConfigDirectory = ".config"

    /// Fixed top-level `$HOME` entries reported by `lstat` alone, relative to `$HOME`. Several
    /// are secret-like, cache, or data locations: they are listed so the report can show them as
    /// excluded, and are never opened or listed.
    public static let wellKnownHomeEntries: [String] = [
        ".aws", ".bash_history", ".cache", ".curlrc", ".docker", ".editorconfig", ".gemrc",
        ".git-credentials", ".gnupg", ".hushlogin", ".inputrc", ".kube", ".netrc", ".npmrc",
        ".pypirc", ".ssh", ".tool-versions", ".vimrc", ".wgetrc", ".zsh_history",
    ]

    /// The tool that owns `relativePath` (relative to `$HOME`): the profile with the longest
    /// config path equal to, or a directory prefix of, `relativePath`.
    public static func owner(of relativePath: FilePath, in tools: [ToolProfile] = tools) -> ToolProfile? {
        var best: (tool: ToolProfile, length: Int)?
        for tool in tools {
            for configPath in tool.configPaths {
                let root = FilePath(configPath)
                guard relativePath.starts(with: root) else { continue }
                let length = root.components.count
                if best.map({ length > $0.length }) ?? true {
                    best = (tool, length)
                }
            }
        }
        return best?.tool
    }
}
