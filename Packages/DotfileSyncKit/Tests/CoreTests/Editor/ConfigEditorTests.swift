import Darwin
import Foundation
import System
import Testing

@testable import Core

@Suite("Config editor")
struct ConfigEditorTests {
    @Test func rejectsSymlinkedAncestor() throws {
        let fixture = try Fixture()
        let original = fixture.root.appending("config")
        let version = try fixture.editor.create(path: original, text: "inside").newVersion
        let outside = fixture.outside.appending("config")
        try fixture.write(outside, "outside")
        try fixture.symlink(fixture.root.appending("link"), pointsTo: fixture.outside)
        let escaped = fixture.root.appending("link/config")

        #expect(throws: EditorError.symlinkEscape) { try fixture.editor.open(path: escaped) }
        #expect(throws: EditorError.symlinkEscape) {
            try fixture.editor.save(path: escaped, text: "changed", expectedVersion: version, force: true)
        }
        #expect(throws: EditorError.symlinkEscape) {
            try fixture.editor.create(path: fixture.root.appending("link/new/config"), text: "new")
        }
        #expect(throws: EditorError.symlinkEscape) {
            try fixture.editor.rename(from: escaped, to: fixture.root.appending("moved"))
        }
        #expect(throws: EditorError.symlinkEscape) {
            try fixture.editor.rename(from: original, to: fixture.root.appending("link/moved"))
        }
        #expect(try fixture.read(outside) == "outside")
        #expect(try fixture.read(original) == "inside")
        #expect(!pathPresent(fixture.outside.appending("new")))
    }

    @Test func rejectsTargetSymlinks() throws {
        let fixture = try Fixture()
        let outside = fixture.outside.appending("config")
        try fixture.write(outside, "outside")
        let original = fixture.root.appending("config")
        let version = try fixture.editor.create(path: original, text: "inside").newVersion
        let link = fixture.root.appending("link")
        let dangling = fixture.root.appending("dangling")
        try fixture.symlink(link, pointsTo: outside)
        try fixture.symlink(dangling, pointsTo: fixture.outside.appending("missing"))

        for target in [link, dangling] {
            #expect(throws: EditorError.symlinkEscape) { try fixture.editor.open(path: target) }
            #expect(throws: EditorError.symlinkEscape) {
                try fixture.editor.save(path: target, text: "changed", expectedVersion: version, force: true)
            }
            #expect(throws: EditorError.symlinkEscape) { try fixture.editor.create(path: target, text: "new") }
            #expect(throws: EditorError.symlinkEscape) {
                try fixture.editor.rename(from: target, to: fixture.root.appending("moved"))
            }
            #expect(throws: EditorError.symlinkEscape) { try fixture.editor.rename(from: original, to: target) }
        }
        #expect(try fixture.read(outside) == "outside")
        #expect(try fixture.read(original) == "inside")
        #expect(pathPresent(link))
        #expect(pathPresent(dangling))
    }

    @Test func rejectsTraversalAndNUL() throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("config")
        let version = try fixture.editor.create(path: path, text: "inside").newVersion
        let traversal = fixture.root.appending("nested/../config")
        #expect(throws: EditorError.pathTraversal) { try fixture.editor.open(path: traversal) }
        #expect(throws: EditorError.pathTraversal) {
            try fixture.editor.create(path: fixture.root.appending("../out/new"), text: "new")
        }

        let nulPath = path.string + "\0suffix"
        #expect(throws: EditorError.pathTraversal) { try fixture.editor.open(path: nulPath) }
        #expect(throws: EditorError.pathTraversal) {
            try fixture.editor.save(path: nulPath, text: "changed", expectedVersion: version, force: true)
        }
        #expect(throws: EditorError.pathTraversal) { try fixture.editor.create(path: nulPath, text: "new") }
        #expect(throws: EditorError.pathTraversal) {
            try fixture.editor.rename(from: path.string, to: nulPath)
        }
        #expect(try fixture.read(path) == "inside")
    }

    @Test func rejectsPathsOutsideRoots() throws {
        let fixture = try Fixture()
        let sibling = fixture.base.appending("fish-other/config")
        try fixture.write(sibling, "outside")
        #expect(throws: EditorError.outsideRoots) { try fixture.editor.open(path: sibling) }
        #expect(throws: EditorError.outsideRoots) { try fixture.editor.open(path: FilePath("fish/config")) }
        #expect(throws: EditorError.notRegularFile) { try fixture.editor.open(path: fixture.root) }
    }

    @Test func rejectsSparseOversizeBeforeReading() throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("sparse")
        let fd = path.withPlatformString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o000) }
        try #require(fd >= 0)
        defer { _ = close(fd) }
        let size = 8 * 1_024 * 1_024 * 1_024
        try #require(ftruncate(fd, off_t(size)) == 0)
        #expect(throws: EditorError.tooLarge(limit: 1_048_576, size: size)) {
            try fixture.editor.open(path: path)
        }
    }

    @Test func boundsNewContentByUTF8Size() throws {
        let fixture = try Fixture(maxFileSize: 5)
        let path = fixture.root.appending("config")
        let version = try fixture.editor.create(path: path, text: "12345").newVersion
        let oversized = "\u{00E9}\u{00E9}\u{00E9}"
        #expect(throws: EditorError.tooLarge(limit: 5, size: 6)) {
            try fixture.editor.save(path: path, text: oversized, expectedVersion: version)
        }
        #expect(throws: EditorError.tooLarge(limit: 5, size: 6)) {
            try fixture.editor.create(path: fixture.root.appending("new/oversized"), text: oversized)
        }
        #expect(try fixture.read(path) == "12345")
        #expect(!pathPresent(fixture.root.appending("new")))
        #expect(!pathPresent(fixture.backups))
    }

    @Test(arguments: [[UInt8(0x61), 0x00], [0xC3, 0x28], [0xEF, 0xBB]])
    func binaryFilesAreViewOnlyAndCannotBeSaved(bytes: [UInt8]) throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("binary")
        try syncFile(path, bytes: bytes)
        let document = try fixture.editor.open(path: path)
        #expect(document.isBinary)
        #expect(document.text == nil)
        #expect(document.bytes == bytes)
        #expect(document.sizeBytes == bytes.count)
        #expect(throws: EditorError.binaryFile) {
            try fixture.editor.save(path: path, text: "changed", expectedVersion: document.version, force: true)
        }
        #expect(try readAllBytes(path) == bytes)
        #expect(!pathPresent(fixture.backups))
    }

    @Test func rejectsNULInNewText() throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("config")
        #expect(throws: EditorError.binaryFile) { try fixture.editor.create(path: path, text: "x\0y") }
        let version = try fixture.editor.create(path: path, text: "original").newVersion
        #expect(throws: EditorError.binaryFile) {
            try fixture.editor.save(path: path, text: "x\0y", expectedVersion: version)
        }
        #expect(try fixture.read(path) == "original")
    }

    @Test func saveAtomicallyPreservesModeAndCopiesBackup() throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("nested/config")
        try fixture.write(path, "original")
        try #require(path.withPlatformString { chmod($0, 0o600) } == 0)
        let preexistingTemp = fixture.root.appending("nested/config.tmp")
        try fixture.write(preexistingTemp, "unrelated")
        let document = try fixture.editor.open(path: path)
        let originalHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path.string))
        defer { try? originalHandle.close() }

        let report = try fixture.editor.save(path: path, text: "abc", expectedVersion: document.version)

        let backup = try #require(report.backupPath)
        #expect(report.path == path)
        #expect(backup == fixture.backups.appending("nested/config.backup.20231114_221320"))
        #expect(try fixture.read(backup) == "original")
        #expect(try originalHandle.readToEnd() == Data("original".utf8))
        let saved = try fixture.editor.open(path: path)
        #expect(saved.text == "abc")
        #expect(saved.mode == 0o600)
        #expect(saved.version == report.newVersion)
        #expect(report.newVersion.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try fixture.read(preexistingTemp) == "unrelated")
        #expect(try fixture.entries(fixture.root.appending("nested")) == ["config", "config.tmp"])
        #expect(try fixture.entries(fixture.backups.appending("nested")) == ["config.backup.20231114_221320"])
    }

    @Test func keepsBothBackupsInTheSameSecond() throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("config")
        let initial = try fixture.editor.create(path: path, text: "one")
        let first = try fixture.editor.save(path: path, text: "two", expectedVersion: initial.newVersion)
        let second = try fixture.editor.save(path: path, text: "three", expectedVersion: first.newVersion)
        let firstBackup = try #require(first.backupPath)
        let secondBackup = try #require(second.backupPath)
        #expect(firstBackup.lastComponent?.string == "config.backup.20231114_221320")
        #expect(secondBackup.lastComponent?.string == "config.backup.20231114_221320.1")
        #expect(try fixture.read(firstBackup) == "one")
        #expect(try fixture.read(secondBackup) == "two")
    }

    @Test func detectsExternalEditEvenWithSameSizeAndMtime() throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("config")
        try fixture.write(path, "original")
        let opened = try fixture.editor.open(path: path)
        var metadata = stat()
        try #require(path.withPlatformString { lstat($0, &metadata) } == 0)
        try fixture.write(path, "external")
        let times = [metadata.st_atimespec, metadata.st_mtimespec]
        try #require(path.withPlatformString { utimensat(AT_FDCWD, $0, times, AT_SYMLINK_NOFOLLOW) } == 0)
        let current = try fixture.editor.open(path: path)
        #expect(current.version.mtimeNs == opened.version.mtimeNs)
        #expect(current.version.size == opened.version.size)
        #expect(current.version.sha256 != opened.version.sha256)

        #expect(throws: EditorError.conflict(current: current.version)) {
            try fixture.editor.save(path: path, text: "edited", expectedVersion: opened.version)
        }
        #expect(try fixture.read(path) == "external")
        #expect(!pathPresent(fixture.backups))

        let forced = try fixture.editor.save(path: path, text: "edited", expectedVersion: opened.version, force: true)
        #expect(try fixture.read(path) == "edited")
        #expect(try fixture.read(#require(forced.backupPath)) == "external")
    }

    @Test func externalWriteBetweenVerifyAndPublishIsReportedAndPreserved() throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("config")
        try fixture.write(path, "original")
        let editor = try ConfigEditor(
            allowedRoots: [fixture.root], backupRoot: fixture.backups, now: { 1_700_000_000_000 },
            confiningRootsTo: nil,
            beforePublish: { target in
                // Another process replaces the file after the editor's check.
                try? syncFile(target, bytes: Array("external!".utf8))
            }
        )
        let opened = try editor.open(path: path)

        do {
            _ = try editor.save(path: path, text: "edited", expectedVersion: opened.version)
            Issue.record("expected conflict")
        } catch {
            guard case let .conflict(current) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(current.sha256 == sha256Hex(Array("external!".utf8)))
        }
        #expect(try fixture.read(path) == "external!")
        #expect(try fixture.entries(fixture.root) == ["config"])
        // The backup is removed on failure, so no stale backup is left behind.
        let backups = pathPresent(fixture.backups) ? try fixture.entries(fixture.backups) : []
        #expect(backups.isEmpty)
    }

    @Test func createsAndRenamesOnlyWithinOneRootWithoutReplacing() throws {
        let fixture = try Fixture()
        let source = fixture.root.appending("new/nested/config")
        let created = try fixture.editor.create(path: source, text: "inside")
        #expect(created.path == source)
        #expect(created.backupPath == nil)
        #expect(try fixture.editor.open(path: source).version == created.newVersion)
        #expect(throws: EditorError.alreadyExists) { try fixture.editor.create(path: source, text: "replaced") }
        let existing = fixture.root.appending("existing")
        _ = try fixture.editor.create(path: existing, text: "keep")
        #expect(throws: EditorError.alreadyExists) { try fixture.editor.rename(from: source, to: existing) }
        let otherRoot = fixture.otherRoot.appending("moved")
        #expect(throws: EditorError.outsideRoots) { try fixture.editor.rename(from: source, to: otherRoot) }
        let outside = fixture.outside.appending("new/moved")
        #expect(throws: EditorError.outsideRoots) { try fixture.editor.create(path: outside, text: "new") }
        #expect(throws: EditorError.outsideRoots) { try fixture.editor.rename(from: source, to: outside) }
        #expect(throws: EditorError.outsideRoots) { try fixture.editor.rename(from: outside, to: source) }

        let destination = fixture.root.appending("moved")
        let renamed = try fixture.editor.rename(from: source, to: destination)
        #expect(renamed.path == destination)
        #expect(renamed.backupPath == nil)
        #expect(renamed.newVersion == created.newVersion)
        #expect(try fixture.editor.open(path: destination).text == "inside")
        #expect(!pathPresent(source))
        #expect(!pathPresent(otherRoot))
        #expect(!pathPresent(fixture.outside.appending("new")))
        #expect(try fixture.read(existing) == "keep")
    }

    @Test func rejectsMissingAndNonregularTargets() throws {
        let fixture = try Fixture()
        let missing = fixture.root.appending("missing")
        let fifo = fixture.root.appending("fifo")
        try #require(fifo.withPlatformString { mkfifo($0, 0o600) } == 0)
        #expect(throws: EditorError.notFound) { try fixture.editor.open(path: missing) }
        #expect(throws: EditorError.notRegularFile) { try fixture.editor.open(path: fifo) }
        #expect(throws: EditorError.notRegularFile) {
            try fixture.editor.rename(from: fifo, to: missing)
        }
        #expect(throws: EditorError.notRegularFile) {
            try fixture.editor.create(path: fifo.appending("config"), text: "new")
        }
    }

    @Test func resolvesConfiguredRootAliasOnce() throws {
        let fixture = try Fixture()
        let alias = fixture.base.appending("alias")
        try fixture.symlink(alias, pointsTo: fixture.root)
        let editor = try ConfigEditor(allowedRoots: [alias], backupRoot: fixture.backups)
        let path = alias.appending("config")
        _ = try editor.create(path: path, text: "inside")

        try #require(alias.withPlatformString { unlink($0) } == 0)
        try fixture.symlink(alias, pointsTo: fixture.outside)
        #expect(try editor.open(path: path).text == "inside")
        #expect(try editor.open(path: fixture.root.appending("config")).text == "inside")
        #expect(!pathPresent(fixture.outside.appending("config")))
    }

    @Test func backupSymlinkFailureLeavesOriginalAndCleansTempFile() throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("config")
        let original = try fixture.editor.create(path: path, text: "original")
        try fixture.symlink(fixture.backups, pointsTo: fixture.outside)
        #expect(throws: EditorError.symlinkEscape) {
            try fixture.editor.save(path: path, text: "changed", expectedVersion: original.newVersion)
        }
        #expect(try fixture.read(path) == "original")
        #expect(try fixture.entries(fixture.root) == ["config"])
        #expect(try fixture.entries(fixture.outside).isEmpty)
    }

    @Test func concurrentSavesWithTheSameVersionHaveOneWinner() async throws {
        let fixture = try Fixture()
        let path = fixture.root.appending("config")
        let version = try fixture.editor.create(path: path, text: "original").newVersion
        let anotherEditor = try ConfigEditor(allowedRoots: [fixture.root], backupRoot: fixture.backups)
        let results = await withTaskGroup(of: Result<EditorWriteReport, EditorError>.self) { group in
            for (index, editor) in [fixture.editor, anotherEditor].enumerated() {
                group.addTask {
                    do throws(EditorError) {
                        return .success(try editor.save(path: path, text: "edit \(index)", expectedVersion: version))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var results: [Result<EditorWriteReport, EditorError>] = []
            for await result in group { results.append(result) }
            return results
        }
        let final = try fixture.editor.open(path: path)
        #expect(results.contains(.failure(.conflict(current: final.version))))
        let successful = results.compactMap { try? $0.get() }
        #expect(successful.count == 1)
        let report = try #require(successful.first)
        #expect(report.newVersion == final.version)
        #expect(try fixture.read(#require(report.backupPath)) == "original")
        #expect(try fixture.entries(fixture.backups).count == 1)
    }
}

private struct Fixture {
    let temporary: TempDir
    let base: FilePath
    let root: FilePath
    let otherRoot: FilePath
    let outside: FilePath
    let backups: FilePath
    let editor: ConfigEditor

    init(maxFileSize: Int = 1_048_576) throws {
        temporary = try TempDir()
        base = try editorCanonicalDirectory(FilePath(temporary.path))
        root = base.appending("fish")
        otherRoot = base.appending("nvim")
        outside = base.appending("out")
        backups = base.appending("backups")
        for directory in [root, otherRoot, outside] { try ensureDir(directory) }
        editor = try ConfigEditor(
            allowedRoots: [root, otherRoot], backupRoot: backups, maxFileSize: maxFileSize, now: { 1_700_000_000_000 }
        )
    }

    func write(_ path: FilePath, _ contents: String) throws {
        try syncFile(path, bytes: Array(contents.utf8))
    }

    func read(_ path: FilePath) throws -> String {
        try String(contentsOfFile: path.string, encoding: .utf8)
    }

    func symlink(_ link: FilePath, pointsTo target: FilePath) throws {
        try #require(target.withPlatformString { destination in
            link.withPlatformString { Darwin.symlink(destination, $0) }
        } == 0)
    }

    func entries(_ path: FilePath) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path.string).sorted()
    }
}
