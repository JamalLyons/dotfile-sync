// Port of crates/dotfilesync-daemon/tests/common/mod.rs. Everything lives in a temp dir;
// nothing touches the real HOME, real Homebrew, launchd or the real data directory.

import Agent
import Core
import Darwin
import Foundation
import IPC
import System
import Testing

let BREW_JSON = #"{"formulae":[{"name":"git","installed":[{"version":"2.44.0"}]}],"casks":[{"token":"ghostty","version":"1.0.0"}]}"#

/// Behaviour of the fake `brew` executable.
enum Brew {
    /// Answers immediately.
    case fast
    /// Sleeps before answering `info`, then succeeds.
    case slow(Double)
    /// Records its pid and hangs on `info` (for cancellation tests).
    case hang
}

/// Repository root (for `fixtures/`).
let repoRoot: FilePath = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return FilePath(url.path)
}()

struct TestFailure: Error, CustomStringConvertible {
    var description: String
}

final class Env {
    let tmp: FilePath
    let layout: DataLayout
    let brew: FilePath
    let pidFile: FilePath
    let runsFile: FilePath
    let home: FilePath

    init(_ mode: Brew) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dfs\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths compare equal to what the agent sees.
        tmp = FilePath(url.resolvingSymlinksInPath().path)
        layout = DataLayout(root: tmp.appending("d"))
        home = tmp.appending("home")
        try FileManager.default.createDirectory(atPath: home.string, withIntermediateDirectories: true)
        pidFile = tmp.appending("brew.pid")
        runsFile = tmp.appending("brew.runs")
        brew = tmp.appending("brew")
        try writeBrew(mode)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tmp.string)
    }

    func writeBrew(_ mode: Brew) throws {
        let info: String
        switch mode {
        case .fast: info = "echo '\(BREW_JSON)'"
        case let .slow(secs): info = "sleep \(secs)\n    echo '\(BREW_JSON)'"
        case .hang: info = "echo $$ > '\(pidFile.string)'\n    exec sleep 30"
        }
        try writeScript(brew, """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            echo "Homebrew 4.3.0"
            exit 0
        fi
        if [ "$1" = "info" ]; then
            echo run >> '\(runsFile.string)'
            \(info)
            exit 0
        fi
        if [ "$1" = "list" ]; then
            exit 0
        fi
        exit 1

        """)
    }

    func config() -> AgentConfig {
        AgentConfig(
            layout: layout,
            brewBin: brew,
            shutdownGrace: .seconds(3),
            heartbeatInterval: .milliseconds(200),
            presence: SkipUserPresence()
        )
    }

    func start(_ config: AgentConfig? = nil) throws -> AgentService {
        try AgentService(config: config ?? self.config())
    }

    /// Number of times the fake brew ran `info`.
    func brewRuns() -> Int {
        guard let s = try? String(contentsOfFile: runsFile.string, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").count
    }

    func waitForBrewPid() throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let s = try? String(contentsOfFile: pidFile.string, encoding: .utf8),
               let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw TestFailure(description: "fake brew never started")
    }
}

func writeScript(_ path: FilePath, _ body: String) throws {
    try body.write(toFile: path.string, atomically: false, encoding: .utf8)
    chmod(path.string, 0o755)
}

func processAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// Kills a stray pid on deinit (e.g. a hung fake brew).
final class PidGuard {
    let pid: pid_t
    init(_ pid: pid_t) { self.pid = pid }
    deinit {
        if pid > 0 { kill(pid, SIGKILL) }
    }
}

func waitUntil(_ timeout: Duration, _ f: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if f() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return f()
}

func modeOf(_ path: FilePath) -> UInt32 {
    var st = stat()
    _ = path.withPlatformString { lstat($0, &st) }
    return UInt32(st.st_mode) & 0o777
}

func readText(_ path: FilePath) -> String {
    (try? String(contentsOfFile: path.string, encoding: .utf8)) ?? ""
}

// MARK: - Typed request helpers (the Rust tests use `Client`; these call the service directly)

extension AgentService {
    func call(_ request: Request) throws(ProtocolError) -> Response {
        try handle(request).get()
    }

    func startJob(_ spec: JobSpec) throws(ProtocolError) -> JobSnapshot {
        guard case let .job(j) = try call(.startJob(spec: spec)) else { throw unexpected() }
        return j
    }

    func jobStatus(_ id: String) throws(ProtocolError) -> JobSnapshot {
        guard case let .job(j) = try call(.jobStatus(jobId: id)) else { throw unexpected() }
        return j
    }

    func listJobs() throws(ProtocolError) -> [JobSnapshot] {
        guard case let .jobs(j) = try call(.listJobs) else { throw unexpected() }
        return j
    }

    func jobProgress(_ id: String, _ since: UInt64) throws(ProtocolError) -> (JobSnapshot, [ProgressEvent], Bool) {
        guard case let .progress(j, e, t) = try call(.jobProgress(jobId: id, sinceSeq: since)) else { throw unexpected() }
        return (j, e, t)
    }

    func jobResult(_ id: String) throws(ProtocolError) -> JobOutput {
        guard case let .jobResult(o) = try call(.jobResult(jobId: id)) else { throw unexpected() }
        return o
    }

    func cancelJob(_ id: String) throws(ProtocolError) -> JobSnapshot {
        guard case let .job(j) = try call(.cancelJob(jobId: id)) else { throw unexpected() }
        return j
    }

    func watchJob(_ id: String, _ since: UInt64, _ onEvent: (ProgressEvent) -> Void = { _ in }) throws(ProtocolError) -> JobSnapshot {
        let outcome = watch(jobId: id, sinceSeq: since) { (n: IPC.Notification) in
            if case let .progress(_, event) = n { onEvent(event) }
            return true
        }
        guard case let .job(j)? = try outcome?.get() else { throw unexpected() }
        return j
    }

    func planCreate(_ input: PlanInput) throws(ProtocolError) -> JobSnapshot {
        guard case let .job(j) = try call(.planCreate(input: input)) else { throw unexpected() }
        return j
    }

    func planApprove(_ planId: String, _ digest: String) throws(ProtocolError) -> ApprovalGrant {
        guard case let .approval(g) = try call(.planApprove(planId: planId, digest: digest)) else { throw unexpected() }
        return g
    }

    func planApply(_ planId: String, _ token: String, _ allowSudo: Bool) throws(ProtocolError) -> JobSnapshot {
        guard case let .job(j) = try call(.planApply(planId: planId, token: token, allowSudo: allowSudo)) else { throw unexpected() }
        return j
    }

    func planResume(_ runId: String, _ token: String, _ allowSudo: Bool) throws(ProtocolError) -> JobSnapshot {
        guard case let .job(j) = try call(.planResume(runId: runId, token: token, allowSudo: allowSudo)) else { throw unexpected() }
        return j
    }

    func planRuns() throws(ProtocolError) -> [RunSummary] {
        guard case let .runs(r) = try call(.planRuns) else { throw unexpected() }
        return r
    }

    func planRunStatus(_ runId: String) throws(ProtocolError) -> RunView {
        guard case let .run(v) = try call(.planRunStatus(runId: runId)) else { throw unexpected() }
        return v
    }

    func waitTerminal(_ id: String, timeout: Duration = .seconds(20)) throws -> JobSnapshot {
        let deadline = ContinuousClock.now + timeout
        while true {
            let job = try jobStatus(id)
            if job.status.isTerminal { return job }
            if ContinuousClock.now >= deadline {
                throw TestFailure(description: "job \(id) did not finish: \(job)")
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    func waitStatus(_ id: String, _ want: JobStatus) throws -> JobSnapshot {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            let j = try jobStatus(id)
            if j.status == want { return j }
            if ContinuousClock.now >= deadline {
                throw TestFailure(description: "job \(id) stuck in \(j.status)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

private func unexpected() -> ProtocolError {
    ProtocolError(.internal, "unexpected response kind")
}

/// The error code of a failed call, or `nil` on success.
func errorCode<T>(_ body: () throws -> T) -> ProtocolError? {
    do {
        _ = try body()
        return nil
    } catch let error as ProtocolError {
        return error
    } catch {
        return ProtocolError(.internal, "non-protocol error: \(error)")
    }
}
