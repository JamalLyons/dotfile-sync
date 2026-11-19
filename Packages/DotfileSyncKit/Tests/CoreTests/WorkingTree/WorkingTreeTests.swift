import Foundation
import System
import Testing

@testable import Core

@Suite("WorkingTree status")
struct WorkingTreeTests {
    @Test func treeCombinesDiscoveryAndManifestInSortedOrder() throws {
        let fixture = try WorkingTreeFixture()
        for name in ["match", "drift", "glob.local", "ignored", "new", "orphan"] {
            try fixture.writeHome(".config/fish/\(name).fish", "machine\n")
        }
        try fixture.writeHome(".config/fish/blocked/nested.fish", "machine\n")
        try fixture.writeHome(".ssh/id_ed25519", "fixture\n")
        try fixture.writeHome(".extra/nested/settings.toml", "same\n")
        try fixture.writeRepo("match.fish", "machine\n")
        try fixture.writeRepo("drift.fish", "repo\n")
        try fixture.writeRepo("deleted.fish", "repo\n")
        try fixture.writeRepo("settings.toml", "same\n")

        let resolved = try fixture.resolve([
            TrackedFile(source: "match.fish", target: "~/.config/fish/match.fish"),
            TrackedFile(source: "drift.fish", target: "~/.config/fish/drift.fish"),
            TrackedFile(source: "absent.fish", target: "~/.config/fish/orphan.fish"),
            TrackedFile(source: "deleted.fish", target: "~/.config/fish/deleted.fish"),
            TrackedFile(source: "settings.toml", target: fixture.home.appending(".extra/nested/settings.toml").string),
        ], exclusions: ExclusionsSection(
            paths: ["~/.config/fish/ignored.fish", "~/.config/fish/blocked"], patterns: ["*.local.fish"]))

        var report = fixture.discover()
        report.truncated = true
        report.diagnostics = [.warning("fixture discovery warning")]
        let tree = buildWorkingTree(report: report, resolved: resolved, home: fixture.home, repoRoot: fixture.repo)
        report.entries.reverse()
        #expect(tree == buildWorkingTree(report: report, resolved: resolved, home: fixture.home, repoRoot: fixture.repo))
        #expect(tree.truncated)
        #expect(tree.diagnostics == report.diagnostics)
        #expect(tree.root.relativePath.isEmpty)
        #expect(tree.root.children?.map(\.relativePath) == [".config", ".extra", ".ssh"])
        let directories = try #require(tree.root.children)
        let fish = try #require(directories[0].children?.first)
        let files = try #require(fish.children)
        #expect(files.map(\.relativePath) == [
            ".config/fish/blocked", ".config/fish/deleted.fish", ".config/fish/drift.fish",
            ".config/fish/glob.local.fish", ".config/fish/ignored.fish", ".config/fish/match.fish",
            ".config/fish/new.fish", ".config/fish/orphan.fish",
        ])
        #expect(files.map(\.status) == [nil, .modified, .modified, .excluded, .excluded, .managed, .unmanaged, .modified])
        #expect(files[0].children?.first?.status == .excluded)
        #expect(files[5].class == .config)
        #expect(files[5].language == .fish)
        #expect(files[5].tool == "fish")
        #expect(files[5].managedSource == "match.fish")
        let absentFromDiscovery = try #require(directories[1].children?.first?.children?.first)
        #expect(absentFromDiscovery.relativePath == ".extra/nested/settings.toml")
        #expect(absentFromDiscovery.status == .managed)
        #expect(absentFromDiscovery.language == .toml)
        #expect(directories[2].class == .secretLike)
        #expect(directories[2].children?.isEmpty == true)
        #expect(directories[2].aggregate?.excluded == 0)
        #expect(fish.aggregate?.managed == 1)
        #expect(fish.aggregate?.modified == 3)
        #expect(fish.aggregate?.unmanaged == 1)
        #expect(fish.aggregate?.excluded == 3)
        #expect(tree.root.aggregate?.managed == 2)
        #expect(tree.root.aggregate?.modified == 3)
        #expect(tree.root.aggregate?.unmanaged == 1)
        #expect(tree.root.aggregate?.excluded == 3)

        let json = try jsonStringCompact(tree)
        #expect(json.contains("\"relative_path\":\".extra/nested/settings.toml\""))
        #expect(json.contains("\"managed_source\":\"settings.toml\""))
        #expect(try JSONDecoder().decode(WorkingTree.self, from: Data(json.utf8)) == tree)
    }

    @Test func excludedPathsSkipInspectorAndBothDiffReaders() throws {
        let fixture = try WorkingTreeFixture()
        let targets = [".env", "alias.conf", "from-alias.conf", "from-excluded.conf", "ignored.conf", "local.conf", "rule.conf"]
        for path in targets where path != "alias.conf" { try fixture.writeHome(path, "fixture\n") }
        try fixture.writeRepo("base.conf", "base\n")
        try fixture.writeRepo(".env", "fixture\n")
        try fixture.link(fixture.home.appending(".env"), at: fixture.home.appending("alias.conf"))
        try fixture.link(fixture.repo.appending(".env"), at: fixture.repo.appending("base-alias.conf"))
        let resolved = try fixture.resolve([
            TrackedFile(source: "base.conf", target: "~/.env"),
            TrackedFile(source: "base.conf", target: "~/alias.conf"),
            TrackedFile(source: "base-alias.conf", target: "~/from-alias.conf"),
            TrackedFile(source: "ignore.conf", target: "~/from-excluded.conf"),
            TrackedFile(source: "base.conf", target: "~/ignored.conf"),
            TrackedFile(source: "base.conf", target: "~/local.conf", machineLocal: true),
            TrackedFile(source: "base.conf", target: "~/rule.conf"),
        ], exclusions: ExclusionsSection(paths: ["ignore.conf", "~/ignored.conf"]))
        let report = ConfigDiscoveryReport(entries: [
            DiscoveredEntry(path: fixture.home.appending("rule.conf"), relativePath: "rule.conf", kind: .file, class: .data),
        ])
        let paths = WorkingTreePaths(report: report, resolved: resolved, home: fixture.home, repoRoot: fixture.repo)
        let tree = makeWorkingTree(report: report, paths: paths) { _ in
            Issue.record("An excluded path reached ConfigInspector")
            return ObservedConfigFile(sourcePath: fixture.repo, targetPath: fixture.home, state: .unreadable)
        }
        #expect(tree.root.aggregate?.excluded == targets.count)
        let recordingReader: WorkingFileReader = { _, _ in
            Issue.record("An excluded path reached the content reader")
            return .bytes([])
        }
        for target in targets {
            #expect(throws: WorkingTreeError.excluded) {
                try diffWorkingFile(target: FilePath(target), paths: paths, maxBytes: 1024,
                                    prepareBase: repositoryDiffBase(read: recordingReader), readTarget: recordingReader)
            }
        }
    }

    @Test func repositoryLinkIsManagedButExternalLinksAreUnreadable() throws {
        let fixture = try WorkingTreeFixture()
        let outside = try TempDir()
        try fixture.writeRepo("base.conf", "base\n")
        try fixture.link(fixture.repo.appending("base.conf"), at: fixture.home.appending("managed.conf"))
        try fixture.link(FilePath(outside.path), at: fixture.home.appending("foreign"))
        try Data("outside\n".utf8).write(to: outside.url.appendingPathComponent("file.conf"))
        let resolved = try fixture.resolve([
            TrackedFile(source: "base.conf", target: "~/managed.conf", mode: .symlink),
            TrackedFile(source: "base.conf", target: "~/foreign/file.conf"),
        ])
        let tree = buildWorkingTree(report: fixture.discover(), resolved: resolved, home: fixture.home, repoRoot: fixture.repo)
        #expect(tree.root.aggregate?.managed == 1)
        #expect(tree.root.aggregate?.modified == 1)
        #expect(try fixture.diff("managed.conf", resolved: resolved).status == .unchanged)
        #expect(throws: WorkingTreeError.unsafePath) { try fixture.diff("foreign/file.conf", resolved: resolved) }
        #expect(throws: WorkingTreeError.invalidTarget) { try fixture.diff("../file.conf", resolved: resolved) }
        #expect(throws: WorkingTreeError.invalidTarget) { try fixture.diff("/outside/file.conf", resolved: resolved) }
    }

    @Test func repositoryUnderExcludedHomePathIsRefused() throws {
        let fixture = try WorkingTreeFixture()
        try fixture.writeHome(".env/base.conf", "fixture\n")
        try fixture.writeHome("main.conf", "machine\n")
        let resolved = try fixture.resolve([TrackedFile(source: "base.conf", target: "~/main.conf")])
        let repo = fixture.home.appending(".env")
        let report = fixture.discover()
        let tree = buildWorkingTree(report: report, resolved: resolved, home: fixture.home, repoRoot: repo)
        #expect(tree.root.children?.first { $0.relativePath == "main.conf" }?.status == .excluded)
        #expect(throws: WorkingTreeError.excluded) {
            try diffWorkingFile(target: "main.conf", resolved: resolved, home: fixture.home, repoRoot: repo)
        }
    }
}

struct WorkingTreeFixture {
    private let homeDirectory: TempDir
    private let repoDirectory: TempDir

    init() throws {
        homeDirectory = try TempDir()
        repoDirectory = try TempDir()
    }

    var home: FilePath { FilePath(homeDirectory.path) }
    var repo: FilePath { FilePath(repoDirectory.path) }

    func resolve(_ files: [TrackedFile], exclusions: ExclusionsSection = ExclusionsSection()) throws -> ResolvedManifest {
        var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
        manifest.files = files
        manifest.exclusions = exclusions
        return try resolveProfile(manifest, selection: .baseOnly, hostname: "fixture", os: .macos)
    }

    func discover() -> ConfigDiscoveryReport {
        discoverConfigs(home: home, environment: ConfigDiscoveryEnvironment(binaryDirectories: [], applicationDirectories: []))
    }

    func diff(_ target: String, resolved: ResolvedManifest, maxBytes: Int = 1_048_576) throws -> ConfigFileDiff {
        try diffWorkingFile(target: FilePath(target), resolved: resolved, home: home, repoRoot: repo, maxBytes: maxBytes)
    }

    func writeHome(_ path: String, _ content: String) throws { try writeHome(path, Data(content.utf8)) }
    func writeHome(_ path: String, _ data: Data) throws { try write(data, at: home.appending(path)) }
    func writeRepo(_ path: String, _ content: String) throws { try writeRepo(path, Data(content.utf8)) }
    func writeRepo(_ path: String, _ data: Data) throws { try write(data, at: repo.appending(path)) }

    func link(_ destination: FilePath, at link: FilePath) throws {
        try FileManager.default.createSymbolicLink(atPath: link.string, withDestinationPath: destination.string)
    }

    private func write(_ data: Data, at path: FilePath) throws {
        let url = URL(fileURLWithPath: path.string)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
