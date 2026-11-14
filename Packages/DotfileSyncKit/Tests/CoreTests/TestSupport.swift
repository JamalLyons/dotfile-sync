import Foundation

/// Locations of shared test inputs. `fixtures/` lives at the repository root and is shared spec data.
enum TestPaths {
    /// Repository root, derived from this file's location (Packages/DotfileSyncKit/Tests/CoreTests).
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // DotfileSyncKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root

    static let fixtures: URL = repoRoot.appendingPathComponent("fixtures")

    static func fixture(_ name: String) -> URL {
        fixtures.appendingPathComponent(name)
    }
}

/// Creates a unique temporary directory and removes it when the returned value is deinitialised.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dotfilesync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path }
}
