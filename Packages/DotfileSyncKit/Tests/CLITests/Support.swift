// Test environment for the CLI. Everything lives in a temp dir: a fake `brew`, a temp HOME and
// a temp data dir. Standalone tests spawn the built `dotfilesync`; agent tests run
// `AgentService` behind an anonymous XPC listener and run the CLI in-process against its
// endpoint. Nothing touches the real HOME, data dir, Homebrew installs, launchd or SMAppService.

import Agent
import AgentRegistration
import CLI
import Core
import Darwin
import Foundation
import IPC
import Synchronization
import System
import Testing
import XPCTransport

let BREW_JSON = #"{"formulae":[{"name":"git","installed":[{"version":"2.44.0"}]}],"casks":[{"token":"ghostty","version":"1.0.0"}]}"#

/// Repository root (for `fixtures/`).
let repoRoot: FilePath = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return FilePath(url.path)
}()

func fixture(_ name: String) -> String {
    repoRoot.appending("fixtures").appending(name).string
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String
}

private final class BundleAnchor {}

/// The built CLI binary, next to the test bundle in the build products directory.
let cliBinary: FilePath = {
    var url = Bundle(for: BundleAnchor.self).bundleURL
    while url.pathExtension != "xctest" && url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
    }
    return FilePath(url.deletingLastPathComponent().appendingPathComponent("dotfilesync").path)
}()

func writeScript(_ path: FilePath, _ body: String) throws {
    try body.write(toFile: path.string, atomically: false, encoding: .utf8)
    chmod(path.string, 0o755)
}

func readText(_ path: FilePath) -> String {
    guard let data = FileManager.default.contents(atPath: path.string) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

func exists(_ path: FilePath) -> Bool {
    FileManager.default.fileExists(atPath: path.string)
}

/// Result of one CLI invocation.
struct Run {
    var code: Int32
    var stdout: String
    var stderr: String

    @discardableResult
    func success(sourceLocation: SourceLocation = #_sourceLocation) -> Run {
        #expect(code == 0, "exit \(code)\nstdout: \(stdout)\nstderr: \(stderr)", sourceLocation: sourceLocation)
        return self
    }

    @discardableResult
    func failure(sourceLocation: SourceLocation = #_sourceLocation) -> Run {
        #expect(code != 0, "expected failure\nstdout: \(stdout)\nstderr: \(stderr)", sourceLocation: sourceLocation)
        return self
    }

    func json(sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else {
            throw TestFailure(description: "stdout is not a JSON object: \(stdout)")
        }
        return object
    }
}

/// Fake brew `info` output variants.
enum BrewInfo {
    /// git + ghostty (cli/daemon tests).
    case gitAndGhostty
    /// git only (plan/apply tests).
    case gitOnly
}

final class Env {
    let tmp: FilePath
    let bin: FilePath
    let home: FilePath
    let data: FilePath

    init(_ info: BrewInfo = .gitAndGhostty) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dfc\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tmp = FilePath(url.resolvingSymlinksInPath().path)
        bin = tmp.appending("bin")
        home = tmp.appending("home")
        data = tmp.appending("d")
        for dir in [bin, home] {
            try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        }
        let json = info == .gitOnly
            ? #"{"formulae":[{"name":"git","installed":[{"version":"2.44.0"}]}],"casks":[]}"#
            : BREW_JSON
        let fallthroughCode = info == .gitOnly ? 0 : 1
        try writeScript(brew, """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "Homebrew 4.3.0"; exit 0; fi
        if [ "$1" = "info" ]; then
          echo '\(json)'
          exit 0
        fi
        exit \(fallthroughCode)

        """)
        // The planner hashes the login shell into the state fingerprint; the real `dscl`
        // occasionally fails under parallel test load, which made plans differ run to run.
        try writeScript(bin.appending("dscl"), """
        #!/bin/sh
        echo "UserShell: /bin/zsh"

        """)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tmp.string)
    }

    var brew: FilePath { bin.appending("brew") }
    var layout: DataLayout { DataLayout(root: data) }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DOTFILESYNC_BREW_BIN")
        env[DATA_DIR_ENV] = data.string
        env["PATH"] = "\(bin.string):/usr/bin:/bin"
        env["HOME"] = home.string
        return env
    }

    /// Spawns the built `dotfilesync` (standalone and not-running scenarios).
    func cli(_ args: [String], extraEnv: [String: String] = [:]) throws -> Run {
        guard FileManager.default.isExecutableFile(atPath: cliBinary.string) else {
            throw TestFailure(description: "dotfilesync not built at \(cliBinary)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinary.string)
        process.arguments = args
        process.environment = environment.merging(extraEnv) { $1 }
        process.currentDirectoryURL = URL(fileURLWithPath: tmp.string)
        // Files, not pipes: concurrent spawns can inherit each other's pipe write ends, which
        // keeps a reader waiting for EOF after the child has exited.
        let outPath = tmp.appending("stdout-\(UUID().uuidString)")
        let errPath = tmp.appending("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outPath.string, contents: nil)
        FileManager.default.createFile(atPath: errPath.string, contents: nil)
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath.string))
        let err = try FileHandle(forWritingTo: URL(fileURLWithPath: errPath.string))
        defer {
            try? out.close()
            try? err.close()
            try? FileManager.default.removeItem(atPath: outPath.string)
            try? FileManager.default.removeItem(atPath: errPath.string)
        }
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return Run(
            code: process.terminationStatus,
            stdout: readText(outPath),
            stderr: readText(errPath)
        )
    }
}

/// Captures stdout/stderr written by an in-process CLI run (progress arrives on XPC queues).
final class Capture: Sendable {
    let out = Mutex("")
    let err = Mutex("")
}

/// A fake SMAppService backend: records calls, never touches launchd.
final class FakeBackend: AgentServiceBackend {
    let state: Mutex<AgentRegistrationStatus>
    let calls = Mutex<[String]>([])

    init(_ status: AgentRegistrationStatus = .notRegistered) {
        state = Mutex(status)
    }

    var status: AgentRegistrationStatus { state.withLock { $0 } }

    func register() throws {
        calls.withLock { $0.append("register") }
        state.withLock { $0 = .enabled }
    }

    func unregister() throws {
        calls.withLock { $0.append("unregister") }
        state.withLock { $0 = .notRegistered }
    }

    func openSystemSettingsLoginItems() {
        calls.withLock { $0.append("open_settings") }
    }
}

/// Runs the CLI in-process. `endpoint` replaces the Mach service; `nil` means no agent is
/// reachable (every connect reports `notRunning`).
func runInProcess(
    _ args: [String],
    env: Env,
    endpoint: XPCEndpointBox?,
    backend: FakeBackend = FakeBackend()
) -> Run {
    let capture = Capture()
    let ctx = CLIContext(
        stdout: { s in capture.out.withLock { $0 += s } },
        stderr: { s in capture.err.withLock { $0 += s } },
        environment: env.environment,
        currentDirectory: env.tmp.string,
        stdinIsTerminal: false,
        readLine: { nil },
        connectAgent: { layout throws(AgentXPCClientError) in
            guard let endpoint else { throw .notRunning(reason: "no test agent") }
            return try AgentXPCClient(endpoint: endpoint.endpoint, layout: layout)
        },
        registration: { AgentRegistration(backend: backend) }
    )
    let code = runCLI(args, context: ctx)
    return Run(code: code, stdout: capture.out.withLock { $0 }, stderr: capture.err.withLock { $0 })
}

import XPC

/// Sendable holder for the test listener's endpoint.
struct XPCEndpointBox: Sendable {
    let endpoint: XPCEndpoint
}

/// `AgentService` behind an anonymous XPC listener (the in-process "daemon").
final class TestAgent {
    let service: AgentService
    let server: AgentXPCServer

    init(_ env: Env) throws {
        let config = AgentConfig(
            layout: env.layout,
            brewBin: env.brew,
            shutdownGrace: .seconds(3),
            heartbeatInterval: .milliseconds(200),
            presence: SkipUserPresence()
        )
        service = try AgentService(config: config)
        let log = try Logger(path: env.layout.logsDir.appending("xpc.log"), maxBytes: 64 * 1024, keep: 1)
        // TEST ONLY: the test runner is ad-hoc signed.
        server = try AgentXPCServer(anonymousFor: service, policy: .insecureAnySigner, log: log)
    }

    var endpoint: XPCEndpointBox {
        get throws {
            guard let endpoint = server.endpoint else { throw TestFailure(description: "no endpoint") }
            return XPCEndpointBox(endpoint: endpoint)
        }
    }

    deinit {
        server.cancel()
        service.shutdown()
    }
}
