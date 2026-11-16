// Ports of the inline tests in crates/dotfilesync-protocol/src/paths.rs.
// `long_socket_path_rejected` is not ported: there is no socket path under XPC.

import Darwin
import Foundation
import IPC
import System
import Testing

final class IPCTempDir {
    let path: FilePath

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dfs-ipc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = FilePath(url.path)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path.string)
    }
}

func modeOf(_ path: FilePath) -> UInt32 {
    var st = stat()
    _ = path.withPlatformString { lstat($0, &st) }
    return UInt32(st.st_mode) & 0o777
}

@Suite struct PathTests {
    @Test func createsPrivateDirsWith0700() throws {
        let tmp = try IPCTempDir()
        let layout = DataLayout(root: tmp.path.appending("data"))
        try layout.ensurePrivateDirs()
        for d in [layout.root, layout.stateDir, layout.runsDir, layout.backupsDir, layout.logsDir] {
            #expect(modeOf(d) == 0o700, "\(d)")
        }
    }

    @Test func refusesPermissiveExistingDirWithoutChangingIt() throws {
        let tmp = try IPCTempDir()
        let dir = tmp.path.appending("open")
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: false)
        chmod(dir.string, 0o755)
        #expect(throws: PathError.tooPermissive(path: dir, mode: 0o755)) {
            try ensurePrivateDir(dir)
        }
        #expect(modeOf(dir) == 0o755)
    }

    @Test func refusesSymlinkedDir() throws {
        let tmp = try IPCTempDir()
        let real = tmp.path.appending("real")
        try FileManager.default.createDirectory(atPath: real.string, withIntermediateDirectories: false)
        chmod(real.string, 0o700)
        let link = tmp.path.appending("link")
        symlink(real.string, link.string)
        #expect(throws: PathError.symlink(path: link)) {
            try checkPrivateDir(link)
        }
    }

    @Test func refusesRegularFile() throws {
        let tmp = try IPCTempDir()
        let f = tmp.path.appending("file")
        FileManager.default.createFile(atPath: f.string, contents: Data("x".utf8))
        #expect(throws: PathError.notADirectory(path: f)) {
            try checkPrivateDir(f)
        }
    }

    @Test func missingIsReportedNotCreated() throws {
        let tmp = try IPCTempDir()
        let p = tmp.path.appending("nope")
        #expect(try checkPrivateDir(p) == .missing)
        #expect(!FileManager.default.fileExists(atPath: p.string))
    }

    @Test func layoutMatchesRustNames() {
        let l = DataLayout(root: FilePath("/d"))
        #expect(l.stateDir == FilePath("/d/state"))
        #expect(l.journal == FilePath("/d/state/jobs.jsonl"))
        #expect(l.runsDir == FilePath("/d/state/runs"))
        #expect(l.backupsDir == FilePath("/d/backups"))
        #expect(l.logsDir == FilePath("/d/logs"))
        #expect(l.logFile == FilePath("/d/logs/dotfilesyncd.log"))
    }

    @Test func resolveOrder() throws {
        #expect(try DataLayout.resolve(explicit: FilePath("/x"), environment: [:]).root == FilePath("/x"))
        #expect(try DataLayout.resolve(environment: [DATA_DIR_ENV: "/e", "HOME": "/h"]).root == FilePath("/e"))
        #expect(try DataLayout.resolve(environment: ["HOME": "/h"]).root
            == FilePath("/h/Library/Application Support/dotfilesync"))
        #expect(throws: PathError.noHome) { try DataLayout.resolve(environment: [:]) }
        let rel = try DataLayout.resolve(explicit: FilePath("rel"), environment: [:])
        #expect(rel.root.isAbsolute)
    }

    @Test func tooPermissiveMessageMatchesRust() {
        let e = PathError.tooPermissive(path: FilePath("/x"), mode: 0o755)
        #expect(e.description == "'/x' has mode 0755, which allows access by other users; run `chmod 700 '/x'` and retry")
    }
}
