import Foundation
import System
import Testing

@testable import Core

/// Extra checks on inspector helpers that reproduce Rust std / glob semantics.
@Suite("Inspector semantics")
struct InspectorSemanticsTests {
    @Test func sha256MatchesKnownDigest() throws {
        let temp = try TempDir()
        let path = "\(temp.path)/f"
        try Data("# Static matching config\nenabled = true\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(try computeSha256(FilePath(path))
            == "7ad54488f714d52ca02e758fdc9fc3222100590ee74bcefddd9f4e152dea5b9f")
        #expect(throws: OSIOError(errno: ENOENT)) { try computeSha256(FilePath("\(temp.path)/missing")) }
        #expect(OSIOError(errno: ENOENT).description == "No such file or directory (os error 2)")
    }

    @Test func rustPathComponentSemantics() {
        #expect(rustPathEqual("/a//b/./c", "/a/b/c"))
        #expect(!rustPathEqual("/a/b", "a/b"))
        #expect(rustPathEndsWith(FilePath("/h/.config/x.conf"), ".config/x.conf"))
        #expect(!rustPathEndsWith(FilePath("/h/.config/xx.conf"), "x.conf"))
        #expect(rustPathStartsWith("/repo/sub/f", "/repo"))
        #expect(!rustPathStartsWith("/repository/f", "/repo"))
        #expect(rustParent("/a/b") == "/a")
        #expect(rustParent("/") == nil)
        #expect(rustParent("m.toml") == "")
    }

    @Test func globMatchesLikeGlobCrate() throws {
        let backup = try #require(GlobPattern("*.backup.*"))
        #expect(backup.matches("config/settings.backup.20261108"))
        #expect(!backup.matches("settings.conf"))
        #expect(try #require(GlobPattern("*.key")).matches("~/.config/priv.key"))
        #expect(try #require(GlobPattern("a?[b-d][!x]")).matches("azcy"))
        #expect(try #require(GlobPattern("**/x")).matches("a/b/x"))
        #expect(GlobPattern("a**") == nil)
        #expect(GlobPattern("[") == nil)
    }

    @Test func directoryTargetIsUnreadable() throws {
        let repo = try TempDir(), home = try TempDir()
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(repo.path)/s"))
        try FileManager.default.createDirectory(atPath: "\(home.path)/t", withIntermediateDirectories: true)
        let inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: ExclusionsSection(), overrides: [])
        let observed = inspector.inspectFile(TrackedFile(source: "s", target: "~/t"))
        #expect(observed.state == .unreadable)
        #expect(observed.diagnostic == "Failed to compute target file checksum: Is a directory (os error 21)")
        #expect(observed.targetSize != nil)
    }

    @Test func absoluteOrTraversalSourceIsOutsideRoot() throws {
        let repo = try TempDir(), home = try TempDir()
        let inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: ExclusionsSection(), overrides: [])
        for source in ["/etc/hosts", "a/../b"] {
            let observed = inspector.inspectFile(TrackedFile(source: source, target: "~/t"))
            #expect(observed.state == .sourceOutsideRoot)
            #expect(observed.diagnostic == "Source path is absolute or contains directory traversal ('..')")
        }
    }

    @Test func relativeSymlinkToSourceIsDetected() throws {
        let repo = try TempDir(), home = try TempDir()
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(repo.path)/s"))
        let relative = String(repeating: "../", count: home.path.split(separator: "/").count) + repo.path.dropFirst() + "/s"
        try FileManager.default.createSymbolicLink(atPath: "\(home.path)/t", withDestinationPath: relative)
        let inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: ExclusionsSection(), overrides: [])
        let observed = inspector.inspectFile(TrackedFile(source: "s", target: "~/t"))
        #expect(observed.state == .symlinkToSource)
        #expect(observed.symlinkTarget == FilePath(relative))
        #expect(observed.targetHash == observed.sourceHash)
    }
}
