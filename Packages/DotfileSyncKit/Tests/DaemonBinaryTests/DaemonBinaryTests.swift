// Port of the real-binary tests in crates/dotfilesync-daemon/tests/state_tests.rs.
//
// The named Mach service only exists when launchd launches the agent, and tests must not
// register anything with launchd. So the built `dotfilesyncd` runs with `--dev-stdio`, which
// serves the same `AgentService` over stdin/stdout JSON lines (and still starts its anonymous
// XPC listener, so the no-network-socket check covers the XPC transport too).

import Core
import Darwin
import Foundation
import IPC
import System
import Testing

/// The built agent binary, next to the test bundle in the build products directory.
let agentBinary: FilePath = {
    // <products>/DotfileSyncKitPackageTests.xctest/Contents/MacOS/<binary> → <products>/dotfilesyncd
    var url = Bundle(for: Agent.self).bundleURL
    while url.pathExtension != "xctest" && url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
    }
    return FilePath(url.deletingLastPathComponent().appendingPathComponent("dotfilesyncd").path)
}()

/// A running `dotfilesyncd --dev-stdio`.
final class Agent {
    let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var buffer = Data()

    init(_ env: Env) throws {
        guard FileManager.default.isExecutableFile(atPath: agentBinary.string) else {
            throw TestFailure(description: "dotfilesyncd not built at \(agentBinary)")
        }
        process.executableURL = URL(fileURLWithPath: agentBinary.string)
        process.arguments = ["--data-dir", env.layout.root.string, "--brew-bin", env.brew.string, "--dev-stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: DATA_DIR_ENV)
        environment["HOME"] = env.home.string
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard case .pong = try call(.ping) else { throw TestFailure(description: "no pong") }
    }

    var pid: pid_t { process.processIdentifier }

    deinit {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    func call(_ request: Request) throws -> Response {
        let body = try JSONEncoder().encode(request)
        stdin.fileHandleForWriting.write(body + Data("\n".utf8))
        let line = try readLine()
        return try JSONDecoder().decode(Outcome.self, from: line).get()
    }

    private func readLine() throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                return Data(line)
            }
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { throw TestFailure(description: "agent closed stdout") }
            buffer.append(chunk)
        }
    }

    func startScan(_ env: Env) throws -> JobSnapshot {
        let spec = JobSpec.scan(ScanInput(manifest: nil, home: env.home, repoRoot: nil, profile: nil))
        guard case let .job(j) = try call(.startJob(spec: spec)) else { throw TestFailure(description: "expected job") }
        return j
    }

    func status(_ id: String) throws -> JobSnapshot {
        guard case let .job(j) = try call(.jobStatus(jobId: id)) else { throw TestFailure(description: "expected job") }
        return j
    }

    /// Sends a signal and waits for exit (bounded).
    func signalAndWait(_ sig: Int32, timeout: Duration = .seconds(15)) throws -> Int32 {
        kill(pid, sig)
        guard waitUntil(timeout, { !process.isRunning }) else {
            throw TestFailure(description: "agent did not exit after signal \(sig)")
        }
        return process.terminationStatus
    }
}

func run(_ tool: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

@Suite(.serialized) struct DaemonBinaryTests {
    @Test func agentBinaryOpensNoTcpOrUdpSockets() throws {
        let env = try Env(.fast)
        let agent = try Agent(env)
        // Exercise it first so lazily created sockets would exist.
        let job = try agent.startScan(env)
        guard case .job = try agent.call(.watchJob(jobId: job.jobId, sinceSeq: 0)) else {
            Issue.record("watch failed")
            return
        }
        let inet = try run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(agent.pid)", "-i"])
        #expect(inet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "agent has network sockets:\n\(inet)")
        // Sanity check that lsof can see this process at all.
        let all = try run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(agent.pid)"])
        #expect(all.contains("dotfilesyncd"), "lsof did not list the process:\n\(all)")
    }

    @Test func sigtermShutsDownGracefullyAndStateStaysConsistent() throws {
        let env = try Env(.fast)
        let agent = try Agent(env)
        let job = try agent.startScan(env)
        #expect(waitUntil(.seconds(10)) { (try? agent.status(job.jobId).status) == .succeeded })
        #expect(try agent.signalAndWait(SIGTERM) == 0)
        let log = readText(env.layout.logFile)
        #expect(log.contains("dotfilesyncd stopped"), "graceful shutdown logged:\n\(log)")

        // Restart immediately (no lock left behind); the finished job is not interrupted.
        let again = try Agent(env)
        let j = try again.status(job.jobId)
        #expect(j.status == .succeeded)
        #expect(j.fromPreviousRun)
        #expect(try again.signalAndWait(SIGINT) == 0)
    }

    @Test func sigkillMidJobThenRestartMarksJobInterruptedWithoutReplay() throws {
        let env = try Env(.hang)
        let agent = try Agent(env)
        let id = try agent.startScan(env).jobId
        let brewPid = try env.waitForBrewPid()
        let brewGuard = PidGuard(brewPid)

        _ = try agent.signalAndWait(SIGKILL)
        kill(brewPid, SIGKILL)
        let runsBefore = env.brewRuns()

        let again = try Agent(env)
        let j = try again.status(id)
        #expect(j.status == .interrupted)
        #expect(j.fromPreviousRun)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(env.brewRuns() == runsBefore, "interrupted work must not be replayed")
        _ = brewGuard
    }

    @Test func dataDirEnvOverrideIsHonoured() throws {
        let env = try Env(.fast)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: agentBinary.string)
        p.arguments = ["--brew-bin", env.brew.string, "--dev-stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment[DATA_DIR_ENV] = env.layout.root.string
        environment["HOME"] = env.home.string
        p.environment = environment
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(#"{"op":"daemon_info"}"#.utf8) + Data("\n".utf8))
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        kill(p.processIdentifier, SIGTERM)
        p.waitUntilExit()
        let outcome = try JSONDecoder().decode(Outcome.self, from: line.prefix { $0 != UInt8(ascii: "\n") })
        guard case let .daemonInfo(info) = try outcome.get() else {
            Issue.record("expected daemon_info")
            return
        }
        #expect(info.dataDir == env.layout.root)
        #expect(p.terminationStatus == 0)
    }

    @Test func refusesUnknownArgumentsAndPrintsVersion() throws {
        let version = try run(agentBinary.string, ["--version"])
        #expect(version.hasPrefix("dotfilesyncd "))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: agentBinary.string)
        p.arguments = ["--bogus"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 2)
    }
}
