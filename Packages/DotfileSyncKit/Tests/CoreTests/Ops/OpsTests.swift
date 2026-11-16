import Foundation
import System
import Testing

@testable import Core

/// Behaviour of the ops.rs port (`run_scan`, `run_status`, helpers).
@Suite("Ops")
struct OpsTests {
    /// Copies the sample manifest next to a temp repo so the default repo root is that repo.
    private static func setUp() throws -> (repo: TempDir, home: TempDir, manifest: FilePath) {
        let repo = try TempDir(), home = try TempDir()
        try FixtureStatusTests.populate(repo: repo.path, home: home.path)
        let manifest = "\(repo.path)/dotfilesync.toml"
        try FileManager.default.copyItem(atPath: TestPaths.fixture("sample_manifest.toml").path, toPath: manifest)
        return (repo, home, FilePath(manifest))
    }

    @Test func runStatusReportsStagesAndMatchesDirectComparison() throws {
        let (repo, home, manifest) = try Self.setUp()
        var stages: [OpStage] = []
        let report = try runStatus(StatusInput(manifest: manifest, home: FilePath(home.path)),
                                   runner: FixtureStatusTests.fixtureRunner(),
                                   progress: { stages.append($0) })
        #expect(stages == [.loadingManifest, .discoveringHomebrew, .inspectingConfigs, .comparing])
        #expect(report.summary == StatusSummary(packagesMatching: 2, packagesMissing: 3, packagesUnmanaged: 1,
                                                configsMatching: 1, configsChanged: 1, configsMissing: 1,
                                                configsSkipped: 1))
        #expect(report.configDifferences.allSatisfy { $0.source.string.hasPrefix(repo.path) })
    }

    @Test func runStatusManifestErrorCarriesPath() throws {
        let home = try TempDir()
        let input = StatusInput(manifest: "/nonexistent/dotfilesync.toml", home: FilePath(home.path))
        do {
            _ = try runStatus(input, runner: MockCommandRunner())
            Issue.record("expected failure")
        } catch {
            guard case let .manifest(path, source) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(path == "/nonexistent/dotfilesync.toml")
            #expect(source == .io(path: "/nonexistent/dotfilesync.toml",
                                  reason: "No such file or directory (os error 2)"))
            #expect(error.description.hasPrefix("failed to load manifest '/nonexistent/dotfilesync.toml': "))
        }
    }

    @Test func runStatusUnknownProfileIsManifestError() throws {
        let (repo, home, manifest) = try Self.setUp()
        defer { withExtendedLifetime(repo) {} }
        #expect(throws: OpError.manifest(path: manifest, source: .unknownProfile(name: "nope"))) {
            try runStatus(StatusInput(manifest: manifest, home: FilePath(home.path), profile: "nope"),
                          runner: MockCommandRunner())
        }
    }

    @Test func runStatusHonoursCancellation() throws {
        let (repo, home, manifest) = try Self.setUp()
        defer { withExtendedLifetime(repo) {} }
        #expect(throws: OpError.cancelled) {
            try runStatus(StatusInput(manifest: manifest, home: FilePath(home.path)),
                          runner: MockCommandRunner(), isCancelled: { true })
        }
    }

    @Test func runScanWithoutManifestAddsInfoDiagnostic() throws {
        let home = try TempDir()
        var stages: [OpStage] = []
        let report = try runScan(ScanInput(manifest: nil, home: FilePath(home.path)),
                                 runner: MockCommandRunner(), progress: { stages.append($0) })
        #expect(stages == [.discoveringHomebrew])
        #expect(report.configs.isEmpty)
        #expect(report.diagnostics == [.info(
            "No manifest specified or found; only Homebrew packages were scanned. "
                + "Use --manifest <path> to inspect tracked configs.")])
    }

    @Test func runScanInspectsConfigs() throws {
        let (repo, home, manifest) = try Self.setUp()
        defer { withExtendedLifetime(repo) {} }
        var stages: [OpStage] = []
        let report = try runScan(ScanInput(manifest: manifest, home: FilePath(home.path)),
                                 runner: FixtureStatusTests.fixtureRunner(), progress: { stages.append($0) })
        #expect(stages == [.discoveringHomebrew, .loadingManifest, .inspectingConfigs])
        #expect(report.diagnostics.isEmpty)
        #expect(report.configs.map(\.state) == [.excluded, .changed, .matching, .missing])
        #expect(report.homebrew.formulae.count == 2)
    }

    @Test func runScanBadManifestBecomesDiagnostic() throws {
        let home = try TempDir()
        let report = try runScan(ScanInput(manifest: "/nonexistent/m.toml", home: FilePath(home.path)),
                                 runner: MockCommandRunner())
        #expect(report.diagnostics == [
            Diagnostic.error("Failed to load manifest at '/nonexistent/m.toml'").withDetail(
                "Failed to read manifest file '/nonexistent/m.toml': No such file or directory (os error 2)"),
        ])
    }

    @Test func runScanUnknownProfileBecomesDiagnostic() throws {
        let (repo, home, manifest) = try Self.setUp()
        defer { withExtendedLifetime(repo) {} }
        let report = try runScan(ScanInput(manifest: manifest, home: FilePath(home.path), profile: "nope"),
                                 runner: MockCommandRunner())
        #expect(report.diagnostics == [
            Diagnostic.error("Failed to resolve manifest profile at '\(manifest.string)'")
                .withDetail("Unknown profile 'nope'"),
        ])
    }

    @Test func defaultRepoRootFallsBack() {
        #expect(defaultRepoRoot(manifest: "/a/b/m.toml", repoRoot: nil) == "/a/b")
        #expect(defaultRepoRoot(manifest: "m.toml", repoRoot: nil) == ".")
        #expect(defaultRepoRoot(manifest: "/a/m.toml", repoRoot: "/r") == "/r")
    }

    @Test func opStageAndInputJSONMatchSerde() throws {
        #expect(try jsonStringCompact(OpStage.discoveringHomebrew) == #""discovering_homebrew""#)
        #expect(OpStage.planning.describe == "Planning changes")
        #expect(try jsonStringCompact(ScanInput(manifest: nil, home: "/h"))
            == #"{"manifest":null,"home":"/h","repo_root":null}"#)
        #expect(try jsonStringCompact(StatusInput(manifest: "/m", home: "/h", repoRoot: "/r", profile: "p"))
            == #"{"manifest":"/m","home":"/h","repo_root":"/r","profile":"p"}"#)
        let decoded = try JSONDecoder().decode(StatusInput.self, from: Data(#"{"manifest":"/m","home":"/h","repo_root":null}"#.utf8))
        #expect(decoded == StatusInput(manifest: "/m", home: "/h"))
    }
}
