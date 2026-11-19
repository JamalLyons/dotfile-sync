import Foundation
import System
import Testing

@testable import Core

@Suite("WorkingTree diffs")
struct WorkingTreeDiffTests {
    @Test func diffRendersInsertDeleteAndChange() throws {
        let fixture = try WorkingTreeFixture()
        let resolved = try fixture.resolve([TrackedFile(source: "base.conf", target: "~/main.conf")])
        try fixture.writeRepo("base.conf", "first\nremove\nthird\nfourth\nlast\n")
        try fixture.writeHome("main.conf", "first\nthird\nfourth\nnew\nchanged\n")

        let diff = try fixture.diff(fixture.home.appending("main.conf").string, resolved: resolved)
        #expect(diff.status == .changed)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 2)
        #expect(diff.unifiedDiff == """
            --- a/main.conf
            +++ b/main.conf
            @@ -1,5 +1,5 @@
             first
            -remove
             third
             fourth
            -last
            +new
            +changed

            """)

        let json = try jsonStringCompact(diff)
        #expect(json.contains("\"old_start\":1"))
        #expect(json.contains("\"target_missing\":false"))
        #expect(try JSONDecoder().decode(ConfigFileDiff.self, from: Data(json.utf8)) == diff)
    }

    @Test func diffSplitsDistantChangesWithThreeLinesOfContext() throws {
        let fixture = try WorkingTreeFixture()
        let resolved = try fixture.resolve([TrackedFile(source: "base", target: "~/file")])
        let base = (1...14).map { "\($0)\n" }
        var current = base
        current[11] = "twelve\n"
        current.insert("inserted\n", at: 1)
        try fixture.writeRepo("base", base.joined())
        try fixture.writeHome("file", current.joined())

        let diff = try fixture.diff("file", resolved: resolved)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 1)
        #expect(diff.unifiedDiff == """
            --- a/file
            +++ b/file
            @@ -1,4 +1,5 @@
             1
            +inserted
             2
             3
             4
            @@ -9,6 +10,6 @@
             9
             10
             11
            -12
            +twelve
             13
             14

            """)
    }

    @Test func diffHandlesMissingSourceTargetAndUnmanaged() throws {
        let fixture = try WorkingTreeFixture()
        let resolved = try fixture.resolve([
            TrackedFile(source: "base", target: "~/deleted"),
            TrackedFile(source: "missing", target: "~/present"),
            TrackedFile(source: "empty", target: "~/inserted"),
        ])
        try fixture.writeRepo("base", "first\nlast")
        try fixture.writeRepo("empty", "")
        try fixture.writeHome("present", "machine\n")
        try fixture.writeHome("inserted", "new\n")
        try fixture.writeHome("unmanaged", "machine\n")

        let deleted = try fixture.diff("deleted", resolved: resolved)
        #expect(deleted.status == .changed)
        #expect(deleted.targetMissing)
        #expect(deleted.additions == 0)
        #expect(deleted.deletions == 2)
        #expect(deleted.unifiedDiff == """
            --- a/deleted
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -first
            -last
            \\ No newline at end of file

            """)
        let inserted = try fixture.diff("inserted", resolved: resolved)
        #expect(inserted.additions == 1)
        #expect(inserted.deletions == 0)
        #expect(inserted.unifiedDiff == "--- a/inserted\n+++ b/inserted\n@@ -0,0 +1 @@\n+new\n")
        let sourceMissing = try fixture.diff("present", resolved: resolved)
        #expect(sourceMissing.status == .noBase)
        #expect(sourceMissing.managedSource == "missing")
        #expect(sourceMissing.unifiedDiff == nil)
        let unmanaged = try fixture.diff("unmanaged", resolved: resolved)
        #expect(unmanaged.status == .noBase)
        #expect(unmanaged.managedSource == nil)
        #expect(unmanaged.unifiedDiff == nil)
    }

    @Test func diffPreservesLineTerminatorsAndByteDistinctUnicode() throws {
        let fixture = try WorkingTreeFixture()
        let resolved = try fixture.resolve([TrackedFile(source: "base", target: "~/file")])
        try fixture.writeRepo("base", "first\r\n\u{00E9}\nlast")
        try fixture.writeHome("file", "first\r\ne\u{0301}\nlast\n")
        let diff = try fixture.diff("file", resolved: resolved)
        let expected = "--- a/file\n+++ b/file\n@@ -1,3 +1,3 @@\n first\r\n-\u{00E9}\n-last\n"
            + "\\ No newline at end of file\n+e\u{0301}\n+last\n"
        #expect(diff.unifiedDiff.map { Array($0.utf8) } == Array(expected.utf8))
        #expect(diff.additions == 2)
        #expect(diff.deletions == 2)
    }

    @Test func diffRejectsBinaryAndOversizedSides() throws {
        let fixture = try WorkingTreeFixture()
        let resolved = try fixture.resolve([TrackedFile(source: "base", target: "~/file")])
        try fixture.writeRepo("base", "base\n")
        try fixture.writeHome("file", Data([0, 65]))
        let nul = try fixture.diff("file", resolved: resolved)
        #expect(nul.status == .binary)
        #expect(nul.hunks.isEmpty)
        #expect(nul.unifiedDiff == nil)
        try fixture.writeHome("file", "text\n")
        try fixture.writeRepo("base", Data([0xFF]))
        #expect(try fixture.diff("file", resolved: resolved).status == .binary)
        let oversized = Data(repeating: 65, count: 1_048_577)
        try fixture.writeRepo("base", oversized)
        #expect(try fixture.diff("file", resolved: resolved).status == .tooLarge)
        try fixture.writeRepo("base", "same\n")
        try fixture.writeHome("file", oversized)
        #expect(try fixture.diff("file", resolved: resolved).status == .tooLarge)
        try fixture.writeHome("file", "same\n")
        #expect(try fixture.diff("file", resolved: resolved, maxBytes: 5).status == .unchanged)
    }

    @Test func diffBoundsHighlyDivergentInputs() throws {
        let fixture = try WorkingTreeFixture()
        let resolved = try fixture.resolve([TrackedFile(source: "base", target: "~/file")])
        try fixture.writeRepo("base", String(repeating: "old\n", count: 1_025))
        try fixture.writeHome("file", String(repeating: "new\n", count: 1_025))
        let diff = try fixture.diff("file", resolved: resolved)
        #expect(diff.status == .tooComplex)
        #expect(diff.hunks.isEmpty)
    }

    @Test func diffProviderCanSupplyABaseAbsentFromTheCheckout() throws {
        let fixture = try WorkingTreeFixture()
        let resolved = try fixture.resolve([TrackedFile(source: "absent/base", target: "~/file")])
        try fixture.writeHome("file", "new\n")
        let paths = WorkingTreePaths(report: nil, resolved: resolved, home: fixture.home, repoRoot: fixture.repo)

        let diff = try diffWorkingFile(target: "file", paths: paths, maxBytes: 1024) { relative, _ in
            #expect(relative == FilePath("absent/base"))
            return WorkingFileBase(repositorySource: nil) { _ in .bytes(Array("old\n".utf8)) }
        } readTarget: { _, _ in
            .bytes(Array("new\n".utf8))
        }
        #expect(diff.unifiedDiff == "--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n")
    }

    @Test func editScriptsReconstructRepeatedLinesWithMinimumEdits() throws {
        let sequences = (0...4).flatMap { count in
            (0..<(1 << count)).map { bits in (0..<count).map { bits & (1 << $0) == 0 ? "a" : "b" } }
        }
        for old in sequences {
            for new in sequences {
                let diff = try #require(lineEdits(from: bytes(old), to: bytes(new)))
                let minimum = distance(old[...], new[...])
                #expect(diff.additions + diff.deletions == minimum)
                if let hunk = diff.hunks.first {
                    #expect(diff.hunks.count == 1)
                    #expect(hunk.lines.filter { !$0.hasPrefix("+") }.map { String($0.dropFirst()) } == old)
                    #expect(hunk.lines.filter { !$0.hasPrefix("-") }.map { String($0.dropFirst()) } == new)
                }
            }
        }
    }

    private func bytes(_ lines: [String]) -> [UInt8] { Array(lines.map { $0 + "\n" }.joined().utf8) }

    private func distance(_ old: ArraySlice<String>, _ new: ArraySlice<String>) -> Int {
        guard let a = old.first, let b = new.first else { return old.count + new.count }
        if a == b { return distance(old.dropFirst(), new.dropFirst()) }
        return 1 + min(distance(old.dropFirst(), new), distance(old, new.dropFirst()))
    }
}
