import Foundation
import System
import Testing

@testable import Core

/// Records every directory listed and every path stat'ed through the real Darwin filesystem.
/// `DiscoveryFileSystem` has no read/open method, so contents cannot be opened through it.
private final class RecordingFileSystem: DiscoveryFileSystem {
    let base = DarwinDiscoveryFileSystem()
    private(set) var listed: [String] = []
    private(set) var statted: [String] = []

    func metadata(_ path: FilePath) -> DiscoveryMetadata? {
        statted.append(path.string)
        return base.metadata(path)
    }

    func listDirectory(_ path: FilePath) throws(OSIOError) -> [String] {
        listed.append(path.string)
        return try base.listDirectory(path)
    }

    func symlinkDestination(_ path: FilePath) -> FilePath? {
        base.symlinkDestination(path)
    }
}

@Suite("Config discovery")
struct ConfigDiscoveryTests {
    private static func write(_ path: String, _ content: String = "x\n") throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private static func symlink(_ destination: String, at path: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    /// Environment with no real search directories, so detection only sees the fixture.
    private static func env(shell: String? = nil, path: String? = nil, bins: [String] = []) -> ConfigDiscoveryEnvironment {
        ConfigDiscoveryEnvironment(
            shell: shell, path: path, binaryDirectories: bins.map { FilePath($0) }, applicationDirectories: [])
    }

    /// A HOME with config, secret, cache, data, and generated content.
    private static func populatedHome() throws -> TempDir {
        let home = try TempDir()
        let h = home.path
        try write("\(h)/.config/fish/config.fish", "set -gx EDITOR nvim\n")
        try write("\(h)/.config/fish/functions/ll.fish")
        try write("\(h)/.config/fish/fish_variables")
        try write("\(h)/.config/fish/logs/fish.log")
        try write("\(h)/.config/nvim/init.lua")
        try write("\(h)/.config/nvim/lazy-lock.json")
        try write("\(h)/.config/nvim/.git/HEAD")
        try write("\(h)/.config/zed/settings.json")
        try write("\(h)/.config/zed/node_modules/pkg/index.js")
        try write("\(h)/.config/zed/Cache/data")
        try write("\(h)/.config/git/config")
        try write("\(h)/.config/starship.toml")
        try write("\(h)/.config/gh/hosts.yml", "oauth_token: hidden\n")
        try write("\(h)/.config/unknowntool/settings.conf")
        try write("\(h)/.zshrc")
        try write("\(h)/.zcompdump")
        try write("\(h)/.zsh_history")
        try write("\(h)/.gitconfig")
        try write("\(h)/.netrc")
        try write("\(h)/.ssh/id_rsa", "PRIVATE\n")
        try write("\(h)/.ssh/config")
        try write("\(h)/.gnupg/pubring.kbx")
        try write("\(h)/.aws/credentials")
        try write("\(h)/.cache/foo/bar")
        try write("\(h)/Documents/notes.txt")
        try write("\(h)/Library/Application Support/com.mitchellh.ghostty/config")
        try write("\(h)/Library/Application Support/OtherApp/state.db")
        return home
    }

    private static func entry(_ report: ConfigDiscoveryReport, _ home: TempDir, _ relative: String) -> DiscoveredEntry? {
        report.entries.first { $0.path == FilePath(home.path).appending(relative) }
    }

    // AC1: Fish detected via $SHELL and via a binary on PATH.
    @Test func fishDetectedViaShellAndBinary() throws {
        let home = try Self.populatedHome()
        let bin = try TempDir()
        try Self.write("\(bin.path)/fish")
        let report = discoverConfigs(
            home: FilePath(home.path),
            environment: Self.env(shell: "/opt/homebrew/bin/fish", path: "relative/ignored:\(bin.path)"),
            fileSystem: RecordingFileSystem())
        let fish = try #require(report.tools.first { $0.id == "fish" })
        #expect(fish.name == "Fish")
        #expect(fish.detectedBy == [.shell, .binary, .configPresent])
        #expect(fish.configRoots == [FilePath(home.path).appending(".config/fish")])
        #expect(Self.entry(report, home, ".config/fish/config.fish")?.tool == "fish")
        #expect(Self.entry(report, home, ".config/fish/config.fish")?.language == .fish)
    }

    @Test func fishDetectedViaShellAlone() throws {
        let home = try TempDir()
        let report = discoverConfigs(
            home: FilePath(home.path), environment: Self.env(shell: "/opt/homebrew/bin/fish"))
        #expect(report.tools.map(\.id) == ["fish"])
        #expect(report.tools[0].detectedBy == [.shell])
        #expect(report.tools[0].configRoots.isEmpty)
        #expect(report.entries.isEmpty)
    }

    @Test func binaryFoundInKnownInstallDirectory() throws {
        let home = try TempDir(), bin = try TempDir()
        try Self.write("\(bin.path)/nvim")
        let report = discoverConfigs(home: FilePath(home.path), environment: Self.env(bins: [bin.path]))
        #expect(report.tools.map(\.id) == ["nvim"])
        #expect(report.tools[0].detectedBy == [.binary])
    }

    // AC1: excluded directories are reported but never listed, and nothing below them appears.
    @Test func excludedDirectoriesAreNeverListed() throws {
        let home = try Self.populatedHome()
        let fs = RecordingFileSystem()
        let report = discoverConfigs(home: FilePath(home.path), environment: Self.env(), fileSystem: fs)
        let h = home.path

        let excludedDirs = [
            ".cache", ".ssh", ".gnupg", ".aws", ".config/fish/logs", ".config/nvim/.git",
            ".config/zed/node_modules", ".config/zed/Cache", ".config/gh",
            ".config/unknowntool", "Library/Application Support/OtherApp", "Documents",
        ]
        for dir in excludedDirs {
            #expect(!fs.listed.contains("\(h)/\(dir)"), "listed \(dir)")
            #expect(!report.entries.contains { $0.path.string.hasPrefix("\(h)/\(dir)/") }, "entries below \(dir)")
            #expect(!fs.statted.contains { $0.hasPrefix("\(h)/\(dir)/") }, "stat below \(dir)")
        }
        #expect(!fs.listed.contains(h), "HOME itself must never be listed")

        for (relative, expected) in [
            (".cache", ConfigClass.cache), (".ssh", .secretLike), (".gnupg", .secretLike),
            (".aws", .secretLike), (".netrc", .secretLike), (".config/fish/logs", .data),
            (".config/nvim/.git", .data), (".zsh_history", .data), (".config/zed/node_modules", .generated),
            (".config/zed/Cache", .cache), (".config/nvim/lazy-lock.json", .generated),
        ] {
            let e = try #require(Self.entry(report, home, relative), "missing \(relative)")
            #expect(e.class == expected, "\(relative)")
            #expect(e.isExcluded)
            #expect(e.excludedReason != nil)
            #expect(e.language == nil)
        }
    }

    // AC1: work is bounded to registry roots and ~/.config (depth 1).
    @Test func listingIsBoundedToRegistryRootsAndXDG() throws {
        let home = try Self.populatedHome()
        let fs = RecordingFileSystem()
        let report = discoverConfigs(home: FilePath(home.path), environment: Self.env(), fileSystem: fs)
        let h = home.path
        let roots = ToolRegistry.tools.flatMap(\.configPaths).map { "\(h)/\($0)" }
        for listed in fs.listed {
            let allowed = listed == "\(h)/.config" || roots.contains { listed == $0 || listed.hasPrefix($0 + "/") }
            #expect(allowed, "listed outside registry roots: \(listed)")
        }
        #expect(fs.listed.contains("\(h)/.config"))
        #expect(!report.truncated)

        // Unknown XDG child surfaces as an unrecognized candidate, metadata only.
        let unknown = try #require(Self.entry(report, home, ".config/unknowntool"))
        #expect(unknown.tool == nil)
        #expect(unknown.kind == .directory)
        #expect(unknown.class == .config)
        // gh is listed as a depth-1 child but its hosts.yml is never reached.
        #expect(Self.entry(report, home, ".config/gh")?.tool == nil)
        #expect(Self.entry(report, home, ".config/gh/hosts.yml") == nil)
        // Application Support profile comes only from the registry.
        #expect(Self.entry(report, home, "Library/Application Support/com.mitchellh.ghostty/config")?.tool == "ghostty")
        #expect(Self.entry(report, home, "Library/Application Support/OtherApp") == nil)
        #expect(Self.entry(report, home, "Documents") == nil)
    }

    @Test func entryLimitTruncates() throws {
        let home = try Self.populatedHome()
        let report = discoverConfigs(
            home: FilePath(home.path), environment: Self.env(),
            limits: ConfigDiscoveryLimits(maxEntries: 3))
        #expect(report.truncated)
        #expect(report.entries.count == 3)
    }

    @Test func depthLimitTruncatesWithoutListingDeeper() throws {
        let home = try TempDir()
        try Self.write("\(home.path)/.config/nvim/lua/plugins/deep/x.lua")
        let fs = RecordingFileSystem()
        let report = discoverConfigs(
            home: FilePath(home.path), environment: Self.env(),
            limits: ConfigDiscoveryLimits(maxDepth: 1), fileSystem: fs)
        #expect(report.truncated)
        #expect(Self.entry(report, home, ".config/nvim/lua")?.kind == .directory)
        #expect(Self.entry(report, home, ".config/nvim/lua/plugins") == nil)
        #expect(!fs.listed.contains("\(home.path)/.config/nvim/lua"))
    }

    @Test func perDirectoryLimitTruncates() throws {
        let home = try TempDir()
        for i in 0..<5 { try Self.write("\(home.path)/.config/fish/functions/f\(i).fish") }
        let report = discoverConfigs(
            home: FilePath(home.path), environment: Self.env(),
            limits: ConfigDiscoveryLimits(maxEntriesPerDirectory: 2))
        #expect(report.truncated)
        #expect(report.entries.filter { $0.relativePath.hasPrefix(".config/fish/functions/") }.count == 2)
    }

    // A symlink pointing outside HOME is reported, not followed.
    @Test func symlinkOutsideHomeIsReportedNotFollowed() throws {
        let home = try TempDir(), outside = try TempDir()
        try Self.write("\(outside.path)/secret-dir/inner.lua")
        try Self.write("\(outside.path)/zed/settings.json")
        try Self.write("\(home.path)/.config/nvim/init.lua")
        try Self.symlink("\(outside.path)/secret-dir", at: "\(home.path)/.config/nvim/linked")
        try Self.symlink("\(outside.path)/zed", at: "\(home.path)/.config/zed")
        try Self.symlink("lua/init.lua", at: "\(home.path)/.config/nvim/relative.lua")

        let fs = RecordingFileSystem()
        let report = discoverConfigs(home: FilePath(home.path), environment: Self.env(), fileSystem: fs)

        let linked = try #require(Self.entry(report, home, ".config/nvim/linked"))
        #expect(linked.kind == .symlink)
        #expect(linked.symlinkTarget == FilePath("\(outside.path)/secret-dir"))
        #expect(linked.symlinkOutsideHome == true)
        #expect(linked.sizeBytes == nil)

        let zed = try #require(Self.entry(report, home, ".config/zed"))
        #expect(zed.kind == .symlink)
        #expect(zed.tool == "zed")
        #expect(zed.symlinkOutsideHome == true)

        let relative = try #require(Self.entry(report, home, ".config/nvim/relative.lua"))
        #expect(relative.symlinkOutsideHome == false)
        #expect(relative.language == .lua)

        #expect(!fs.listed.contains { $0.hasPrefix(outside.path) })
        #expect(!fs.statted.contains { $0.hasPrefix(outside.path) })
        #expect(!fs.listed.contains("\(home.path)/.config/nvim/linked"))
        #expect(!report.entries.contains { $0.relativePath.hasPrefix(".config/zed/") })
    }

    @Test func symlinkedConfigAncestorIsNotTraversed() throws {
        let home = try TempDir(), outside = try TempDir()
        try Self.write("\(outside.path)/fish/config.fish")
        try Self.symlink(outside.path, at: "\(home.path)/.config")
        let fs = RecordingFileSystem()
        let report = discoverConfigs(home: FilePath(home.path), environment: Self.env(), fileSystem: fs)
        #expect(report.entries.map(\.relativePath) == [".config"])
        #expect(report.entries[0].kind == .symlink)
        #expect(fs.listed.isEmpty)
    }

    @Test func outputIsSortedDeterministicAndSnakeCase() throws {
        let home = try Self.populatedHome()
        let first = discoverConfigs(home: FilePath(home.path), environment: Self.env(shell: "/bin/zsh"))
        let second = discoverConfigs(home: FilePath(home.path), environment: Self.env(shell: "/bin/zsh"))
        #expect(first == second)
        #expect(first.entries.map(\.path.string) == first.entries.map(\.path.string).sorted())
        #expect(first.tools.map(\.id) == first.tools.map(\.id).sorted())

        let rc = try #require(Self.entry(first, home, ".zshrc"))
        #expect(rc.tool == "zsh")
        #expect(rc.sizeBytes == 2)
        let json = try jsonStringCompact(rc)
        #expect(json.contains("\"relative_path\":\".zshrc\""))
        #expect(json.contains("\"size_bytes\":2"))
        #expect(json.contains("\"class\":\"config\""))
        #expect(json.contains("\"language\":\"shell\""))
        #expect(!json.contains("excluded_reason"))

        let ssh = try jsonStringCompact(try #require(Self.entry(first, home, ".ssh")))
        #expect(ssh.contains("\"class\":\"secret_like\""))
        #expect(ssh.contains("\"excluded_reason\""))

        let tool = try jsonStringCompact(try #require(first.tools.first { $0.id == "zsh" }))
        #expect(tool.contains("\"detected_by\":[\"shell\",\"config_present\"]"))
        #expect(tool.contains("\"config_roots\""))

        let data = try JSONEncoder().encode(first)
        #expect(try JSONDecoder().decode(ConfigDiscoveryReport.self, from: data) == first)
    }
}
