import System
import Testing

@testable import Core

/// AC2: rule-based classification and language detection, both pure.
@Suite("Config discovery classification")
struct ConfigDiscoveryClassificationTests {
    private static func cls(_ path: String) -> ConfigClass {
        classifyConfigPath(FilePath(path)).class
    }

    @Test(arguments: [
        ".config/fish/config.fish", ".config/fish/functions/ll.fish", ".zshrc", ".gitconfig",
        ".config/git/config", ".config/zed/settings.json", ".config/zed/keymap.json",
        ".config/nvim/init.lua", ".config/starship.toml", ".tmux.conf",
        "Library/Application Support/com.mitchellh.ghostty/config",
    ])
    func config(_ path: String) {
        let result = classifyConfigPath(FilePath(path))
        #expect(result.class == .config)
        #expect(result.reason == nil)
    }

    @Test(arguments: [
        ".ssh", ".ssh/config", ".gnupg", ".aws/config", ".netrc", ".npmrc", ".git-credentials",
        ".config/gh/hosts.yml", ".config/fish/conf.d/secrets.fish", ".config/app/api_token",
        ".config/app/credentials.json", ".config/app/server.pem", ".config/app/tls.key",
        ".config/app/id_rsa", ".config/app/id_ed25519.pub", ".config/app/.env",
        ".config/app/.env.local", ".config/app/password.txt",
    ])
    func secretLike(_ path: String) {
        #expect(Self.cls(path) == .secretLike)
        #expect(classifyConfigPath(FilePath(path)).reason?.hasPrefix("secret-like") == true)
    }

    /// Unregistered depth-1 ~/.config children are `unknown` in discovery, excluded by default.
    @Test(arguments: [".config/app", ".config/fishy", ".config/gh", ".config/unknowntool"])
    func unknownChild(_ path: String) {
        let result = classifyDiscoveredPath(FilePath(path))
        #expect(result.class == .unknown)
        #expect(result.class.isExcludedByDefault)
        #expect(result.reason?.hasPrefix("unknown") == true)
    }

    /// Registry-owned children stay `config`, and the pure classifier never returns `unknown`.
    @Test func unknownIsDiscoveryOnly() {
        #expect(classifyDiscoveredPath(FilePath(".config/fish")).class == .config)
        #expect(classifyDiscoveredPath(FilePath(".config/nvim")).class == .config)
        #expect(classifyConfigPath(FilePath(".config/app")).class == .config)
        #expect(classifyConfigPath(FilePath(".config/app/x.conf")).class == .config)
    }

    /// Rules that match earlier than the unknown fallback still win for unregistered children.
    @Test func ruleBeforeUnknownFallback() {
        #expect(Self.cls(".config/app/api_token") == .secretLike)
        #expect(Self.cls(".config/app/Caches/x") == .cache)
        #expect(Self.cls(".config/app/logs") == .data)
        #expect(Self.cls(".config/app/__pycache__") == .generated)
    }

    @Test(arguments: [
        ".cache", ".cache/foo/bar", ".config/zed/Cache", ".config/app/Caches/x",
        ".config/app/GPUCache", ".config/app/index.cache", ".config/nvim/node-cache.json",
        ".config/nvim/cache_dir/x", ".config/nvim/Code Cache/x", ".config/nvim/appcache",
    ])
    func cache(_ path: String) {
        #expect(Self.cls(path) == .cache)
    }

    /// Substring matches inside a longer word are not cache. These paths are owned by nvim, so
    /// any non-config class here would come from a rule, not from the unknown fallback.
    @Test(arguments: [
        ".config/nvim/cachet.lua", ".config/nvim/mycachetool.lua", ".config/nvim/cachedir.lua",
        ".config/nvim/precache.lua",
    ])
    func cacheSubstringFalsePositives(_ path: String) {
        #expect(Self.cls(path) == .config)
    }

    /// Words that contain `token`, `secret`, or `password` but are not those words stay config.
    @Test(arguments: [
        ".config/nvim/tokenizer.lua", ".config/nvim/secretary.lua", ".config/nvim/passwordless.md",
        ".config/nvim/secretive.lua",
    ])
    func secretSubstringFalsePositives(_ path: String) {
        #expect(Self.cls(path) == .config)
    }

    @Test(arguments: [
        ".zsh_history", ".bash_history", ".local/share/fish/fish_history", ".config/fish/fish_variables",
        ".config/app/logs", ".config/app/logs/today.txt", ".config/app/debug.log",
        ".config/app/state.sqlite", ".config/app/store.db", ".config/app/store.db-wal",
        ".config/nvim/.git", ".config/nvim/.git/HEAD", ".config/app/.DS_Store",
    ])
    func data(_ path: String) {
        #expect(Self.cls(path) == .data)
    }

    @Test(arguments: [
        ".zshrc.zwc", ".zcompdump", ".zcompdump-host-5.9", ".config/nvim/lazy-lock.json",
        ".config/nvim/plugin/packer_compiled.lua", ".config/app/__pycache__", ".config/app/mod.pyc",
        ".config/app/node_modules", ".config/app/Cargo.lock", ".config/nvim/.init.lua.swp",
        ".config/app/settings.json~",
    ])
    func generated(_ path: String) {
        #expect(Self.cls(path) == .generated)
    }

    @Test func secretTakesPrecedence() {
        // A log under ~/.ssh is still secret-like; a token cache is secret-like, not cache.
        #expect(Self.cls(".ssh/logs/x.log") == .secretLike)
        #expect(Self.cls(".config/app/token.cache") == .secretLike)
        #expect(Self.cls(".cache/history") == .data)
    }

    @Test func onlyConfigIsIncludedByDefault() {
        #expect(ConfigClass.allCases.filter { !$0.isExcludedByDefault } == [.config])
    }

    @Test(arguments: [
        (".config/fish/config.fish", ConfigLanguage.fish),
        (".config/starship.toml", .toml),
        (".config/zed/settings.json", .json),
        (".config/app/conf.jsonc", .json),
        (".config/app/conf.yml", .yaml),
        (".config/app/conf.yaml", .yaml),
        (".zshrc", .shell), (".bashrc", .shell), (".bash_profile", .shell), (".profile", .shell),
        (".zprofile", .shell), (".zshenv", .shell), (".config/zsh/aliases.zsh", .shell),
        (".config/app/run.sh", .shell),
        (".config/nvim/init.lua", .lua),
        (".gitconfig", .gitconfig), (".config/git/config", .gitconfig),
        (".config/app/settings.ini", .ini), (".editorconfig", .ini),
        (".config/ghostty/config", .plaintext), (".tmux.conf", .plaintext), ("", .plaintext),
    ])
    func language(_ path: String, _ expected: ConfigLanguage) {
        #expect(detectConfigLanguage(FilePath(path)) == expected)
    }

    @Test func supportedLanguagesListed() {
        #expect(ConfigLanguage.supported.map(\.rawValue) == [
            "fish", "toml", "json", "yaml", "shell", "lua", "gitconfig", "ini", "plaintext",
        ])
    }

    @Test func registryOwnerUsesLongestPrefix() {
        #expect(ToolRegistry.owner(of: ".config/fish/conf.d/a.fish")?.id == "fish")
        #expect(ToolRegistry.owner(of: ".config/starship.toml")?.id == "starship")
        #expect(ToolRegistry.owner(of: ".config/fishy") == nil)
        #expect(ToolRegistry.owner(of: ".ssh/config") == nil)
        #expect(!ToolRegistry.tools.flatMap(\.configPaths).contains { $0.hasPrefix(".ssh") })
        #expect(ToolRegistry.tools.map(\.id) == ToolRegistry.tools.map(\.id).sorted())
    }
}
