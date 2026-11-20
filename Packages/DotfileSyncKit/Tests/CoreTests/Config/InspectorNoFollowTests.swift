import Darwin
import Foundation
import Synchronization
import System
import Testing

@testable import Core

/// The inspector hashes from the descriptor it validated and refuses files replaced by symlinks.
@Suite("Inspector no-follow reads")
struct InspectorNoFollowTests {
    private static func write(_ path: String, _ content: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Replaces the file at `path` with a symlink to `destination` the first time `path` is opened.
    private static func swapHook(
        at path: String, to destination: String
    ) -> @Sendable (FilePath) -> Void {
        let swapped = Mutex(false)
        return { opened in
            guard opened.lastComponent == FilePath(path).lastComponent else { return }
            let first = swapped.withLock { done in
                defer { done = true }
                return !done
            }
            guard first else { return }
            _ = unlink(path)
            _ = symlink(destination, path)
        }
    }

    @Test func targetSwappedForSymlinkBeforeOpenIsRefused() throws {
        let repo = try TempDir(), home = try TempDir(), outside = try TempDir()
        try Self.write("\(repo.path)/s.conf", "SAME\n")
        try Self.write("\(home.path)/t.conf", "machine\n")
        let secret = "\(outside.path)/secret"
        try Self.write(secret, "SAME\n")

        var inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: ExclusionsSection(), overrides: [])
        inspector.beforeOpen = Self.swapHook(at: "\(home.path)/t.conf", to: secret)
        let observed = inspector.inspectFile(TrackedFile(source: "s.conf", target: "~/t.conf"))

        #expect(observed.state == .unreadable)
        #expect(observed.targetHash == nil)
        #expect(observed.sourceHash != nil)
        let diagnostic = try #require(observed.diagnostic)
        #expect(diagnostic.hasPrefix("Failed to compute target file checksum: "))
        #expect(diagnostic.contains("(os error \(ELOOP))"))
    }

    @Test func sourceSwappedForSymlinkBeforeOpenIsRefused() throws {
        let repo = try TempDir(), home = try TempDir(), outside = try TempDir()
        try Self.write("\(repo.path)/s.conf", "repo\n")
        try Self.write("\(home.path)/t.conf", "OUTSIDE\n")
        let secret = "\(outside.path)/secret"
        try Self.write(secret, "OUTSIDE\n")

        var inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: ExclusionsSection(), overrides: [])
        inspector.beforeOpen = Self.swapHook(at: "\(repo.path)/s.conf", to: secret)
        let observed = inspector.inspectFile(TrackedFile(source: "s.conf", target: "~/t.conf"))

        #expect(observed.state == .unreadable)
        #expect(observed.sourceHash == nil)
        let diagnostic = try #require(observed.diagnostic)
        #expect(diagnostic.hasPrefix("Failed to compute hash for source file: "))
        #expect(diagnostic.contains("(os error \(ELOOP))"))
    }

    @Test func sourceParentSwappedForSymlinkBeforeOpenIsRefused() throws {
        let repo = try TempDir(), home = try TempDir(), outside = try TempDir()
        try Self.write("\(repo.path)/dir/s.conf", "repo\n")
        try Self.write("\(home.path)/t.conf", "OUTSIDE\n")
        try Self.write("\(outside.path)/s.conf", "OUTSIDE\n")

        var inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: ExclusionsSection(), overrides: [])
        let directory = "\(repo.path)/dir"
        let outsidePath = outside.path
        inspector.beforeOpen = { opened in
            guard opened.lastComponent == "s.conf", FileManager.default.fileExists(atPath: directory + "/s.conf"),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: directory)) == nil else { return }
            try? FileManager.default.removeItem(atPath: directory)
            _ = symlink(outsidePath, directory)
        }
        let observed = inspector.inspectFile(TrackedFile(source: "dir/s.conf", target: "~/t.conf"))

        #expect(observed.state == .unreadable)
        #expect(observed.sourceHash == nil)
        #expect(try #require(observed.diagnostic).hasPrefix("Failed to compute hash for source file: "))
    }

    @Test func targetReplacedByDifferentFileBeforeOpenIsRefused() throws {
        let repo = try TempDir(), home = try TempDir()
        try Self.write("\(repo.path)/s.conf", "SAME\n")
        let target = "\(home.path)/t.conf"
        try Self.write(target, "machine\n")

        var inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: ExclusionsSection(), overrides: [])
        let replaced = Mutex(false)
        inspector.beforeOpen = { opened in
            guard opened.lastComponent == "t.conf", !replaced.withLock({ $0 }) else { return }
            replaced.withLock { $0 = true }
            let staging = target + ".new"
            try? Data("SAME\n".utf8).write(to: URL(fileURLWithPath: staging))
            _ = rename(staging, target)
        }
        let observed = inspector.inspectFile(TrackedFile(source: "s.conf", target: "~/t.conf"))

        #expect(observed.state == .unreadable)
        #expect(observed.targetHash == nil)
        #expect(observed.diagnostic
            == "Failed to compute target file checksum: file was replaced while it was being inspected")
    }

    @Test func fifoTargetIsUnreadableWithoutBlocking() throws {
        let repo = try TempDir(), home = try TempDir()
        try Self.write("\(repo.path)/s.conf", "x\n")
        let target = "\(home.path)/t.conf"
        #expect(mkfifo(target, 0o600) == 0)

        let inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: ExclusionsSection(), overrides: [])
        let observed = inspector.inspectFile(TrackedFile(source: "s.conf", target: "~/t.conf"))
        #expect(observed.state == .unreadable)
        #expect(observed.diagnostic == "Failed to compute target file checksum: \(OSIOError(errno: EFTYPE))")
    }

    @Test func unchangedFilesStillHashThroughDescriptor() throws {
        let repo = try TempDir(), home = try TempDir()
        try Self.write("\(repo.path)/s.conf", "same\n")
        try Self.write("\(home.path)/t.conf", "same\n")
        var inspector = ConfigInspector(repoRoot: FilePath(repo.path), homeDir: FilePath(home.path),
                                        exclusions: ExclusionsSection(), overrides: [])
        let opened = Mutex<[String]>([])
        inspector.beforeOpen = { path in opened.withLock { $0.append(path.lastComponent?.string ?? "") } }
        let observed = inspector.inspectFile(TrackedFile(source: "s.conf", target: "~/t.conf"))
        #expect(observed.state == .matching)
        #expect(observed.sourceHash == observed.targetHash)
        #expect(opened.withLock { $0 } == ["s.conf", "t.conf"])
    }
}
