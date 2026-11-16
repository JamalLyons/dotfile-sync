// Port of crates/dotfilesync-cli/src/commands/{mode,remote}.rs: choosing between the agent and
// standalone execution, explaining the choice, and running jobs through the agent over XPC.

import ArgumentParser
import Core
import Foundation
import IPC
import Synchronization
import System
import XPCTransport

/// Where a command runs (`--mode`).
public enum Mode: String, CaseIterable, Sendable, ExpressibleByArgument {
    /// Use the agent if it is running, otherwise run in this process.
    case auto
    /// Require the agent; fail with an explanation if it is not running.
    case daemon
    /// Always run in this process without contacting the agent.
    case standalone

    /// Accepts `agent` as a synonym for `daemon`.
    public init?(argument: String) {
        switch argument {
        case "auto": self = .auto
        case "daemon", "agent": self = .daemon
        case "standalone": self = .standalone
        default: return nil
        }
    }

    public static var allValueStrings: [String] { ["auto", "daemon", "standalone"] }
}

/// Hint appended when the agent is not running. The Rust CLI pointed at
/// `dotfilesync service start/install` (launchctl); the agent is now registered with
/// SMAppService and launchd starts it on demand.
let NOT_RUNNING_HINT =
    "Register it with `dotfilesync service install` (launchd then starts it on demand), or run `dotfilesyncd` from the app bundle."

/// A connected agent plus the `daemon_info` it answered with.
final class AgentConnection: Sendable {
    let client: AgentXPCClient
    let info: DaemonInfo

    init(client: AgentXPCClient, info: DaemonInfo) {
        self.client = client
        self.info = info
    }

    /// Sends `request`, turning transport and agent errors into user-facing errors.
    func call(_ request: Request) throws(CLIError) -> Response {
        let outcome: Outcome
        do {
            outcome = try client.send(request)
        } catch {
            throw CLIError("\(error)")
        }
        switch outcome {
        case let .ok(response): return response
        case let .err(error): throw remoteError(error)
        }
    }

    func job(_ request: Request) throws(CLIError) -> JobSnapshot {
        let response = try call(request)
        guard case let .job(snapshot) = response else { throw unexpectedResponse(response) }
        return snapshot
    }

    /// Streams progress for `jobId` after `since` to `onEvent`, returning the terminal snapshot.
    func watch(_ jobId: String, since: UInt64, onEvent: @escaping @Sendable (ProgressEvent) -> Void) throws(CLIError) -> JobSnapshot {
        let outcome: Outcome?
        do {
            outcome = try client.watch(jobId: jobId, sinceSeq: since) { notification in
                if case let .progress(_, event) = notification {
                    onEvent(event)
                }
                return true
            }
        } catch {
            throw CLIError("\(error)")
        }
        switch outcome {
        case let .ok(.job(snapshot))?: return snapshot
        case let .ok(other)?: throw unexpectedResponse(other)
        case let .err(error)?: throw remoteError(error)
        case nil: throw CLIError("the watch of job \(jobId) ended before the job finished")
        }
    }
}

/// Rust `ClientError::Remote` display: `daemon returned an error: <message> (<Debug code>)`.
func remoteError(_ error: ProtocolError) -> CLIError {
    CLIError("daemon returned an error: \(error.message) (\(debugCase(error.code)))")
}

func unexpectedResponse(_ response: Response) -> CLIError {
    CLIError("protocol error: unexpected response \(response)")
}

/// Rust `{:?}` of a unit enum variant: the PascalCase case name.
func debugCase<T>(_ value: T) -> String {
    let name = "\(value)"
    return name.prefix(1).uppercased() + name.dropFirst()
}

/// Turns a transport error into an explanation (Rust `mode::explain`).
func explain(_ error: AgentXPCClientError, layout: DataLayout) -> CLIError {
    switch error {
    case let .notRunning(reason):
        // Rust: "dotfilesyncd is not running (socket …: <reason>)".
        return CLIError("dotfilesyncd is not running (\(reason)). \(NOT_RUNNING_HINT)")
    case .dataDir:
        return CLIError("\(error). The data directory \(layout.root.string) must be owned by you with mode 0700.")
    default:
        return CLIError("\(error). Use --mode standalone to bypass the daemon.")
    }
}

func resolveLayout(_ dataDir: FilePath?, _ ctx: CLIContext) throws(CLIError) -> DataLayout {
    do {
        return try DataLayout.resolve(explicit: dataDir, environment: ctx.environment)
    } catch {
        throw CLIError(error.description)
    }
}

/// Connects and handshakes (`daemon_info`); the raw transport error is kept for routing.
func tryConnect(_ layout: DataLayout, _ ctx: CLIContext) throws(AgentXPCClientError) -> AgentConnection {
    let client = try ctx.connectAgent(layout)
    let outcome = try client.send(.daemonInfo)
    switch outcome {
    case let .ok(.daemonInfo(info)):
        return AgentConnection(client: client, info: info)
    case let .ok(other):
        throw .protocolViolation("expected daemon_info, got \(other)")
    case let .err(error):
        throw .protocolViolation("daemon_info failed: \(error)")
    }
}

/// Connects to the agent or explains why not (Rust `mode::connect`).
func connect(_ dataDir: FilePath?, _ ctx: CLIContext) throws(CLIError) -> AgentConnection {
    let layout = try resolveLayout(dataDir, ctx)
    do {
        return try tryConnect(layout, ctx)
    } catch {
        throw explain(error, layout: layout)
    }
}

enum Route {
    case agent(AgentConnection)
    /// `note` explains why auto mode fell back (printed to stderr).
    case standalone(note: String?)
}

/// Decides where `command` runs. `standaloneOnly` names a flag the agent cannot honor.
func route(
    _ mode: Mode,
    dataDir: FilePath?,
    command: String,
    standaloneOnly: String?,
    _ ctx: CLIContext
) throws(CLIError) -> Route {
    if mode == .standalone {
        return .standalone(note: nil)
    }
    if let flag = standaloneOnly {
        let why = "\(flag) only applies to standalone mode (the daemon uses its own configured Homebrew)"
        if mode == .daemon {
            throw CLIError("\(why); drop \(flag) or use --mode standalone")
        }
        return .standalone(note: "note: \(why); running \(command) standalone in this process.")
    }
    let layout: DataLayout
    do {
        layout = try DataLayout.resolve(explicit: dataDir, environment: ctx.environment)
    } catch {
        if mode == .auto {
            return .standalone(note: "note: cannot locate the dotfilesyncd data directory (\(error)); running \(command) standalone in this process.")
        }
        throw CLIError(error.description)
    }
    do {
        return .agent(try tryConnect(layout, ctx))
    } catch {
        if error.isNotRunning && mode == .auto {
            return .standalone(
                note: "note: dotfilesyncd is not running; running \(command) standalone in this process. \(NOT_RUNNING_HINT)"
            )
        }
        throw explain(error, layout: layout)
    }
}

/// `std::path::absolute`: relative paths are joined to the current directory.
func absolute(_ path: FilePath, _ ctx: CLIContext) -> FilePath {
    if path.isAbsolute {
        return path
    }
    return FilePath(ctx.currentDirectory).pushing(path)
}

// MARK: - Jobs (Rust remote.rs)

enum Remote {
    case detached(JobSnapshot)
    case finished(JobOutput)
    /// Terminal but not successful (failed, cancelled, interrupted).
    case failed(JobSnapshot)
}

/// Starts `spec`, streams progress to stderr (unless `quiet`) and fetches the result.
/// Interrupting the CLI only drops this client; the job keeps running.
func runJob(_ conn: AgentConnection, _ spec: JobSpec, detach: Bool, quiet: Bool, _ ctx: CLIContext) throws(CLIError) -> Remote {
    let job = try conn.job(.startJob(spec: spec))
    let id = job.jobId
    ctx.err("dotfilesyncd (pid \(conn.info.pid)) is running \(job.kind) as job \(id).")
    if detach {
        ctx.err("Detached. Follow it with `dotfilesync jobs watch \(id)`.")
        return .detached(job)
    }
    return try follow(conn, job, quiet: quiet, ctx)
}

/// Watches a job that is already running.
func follow(_ conn: AgentConnection, _ job: JobSnapshot, quiet: Bool, _ ctx: CLIContext) throws(CLIError) -> Remote {
    let id = job.jobId
    if !quiet {
        ctx.err("Ctrl-C detaches without cancelling. Follow it with `dotfilesync jobs follow \(id)`.")
    }
    let final: JobSnapshot
    do {
        final = try conn.watch(id, since: 0) { event in
            if !quiet {
                ctx.err("  [\(event.stage)] \(event.message)")
            }
        }
    } catch {
        ctx.err("Disconnected from job \(id) (\(error)). It keeps running.")
        ctx.err("Follow it with `dotfilesync jobs follow \(id)`.")
        throw error
    }
    return try finish(conn, final)
}

func finish(_ conn: AgentConnection, _ job: JobSnapshot) throws(CLIError) -> Remote {
    switch job.status {
    case .succeeded:
        let response = try conn.call(.jobResult(jobId: job.jobId))
        guard case let .jobResult(output) = response else { throw unexpectedResponse(response) }
        return .finished(output)
    case .queued, .running:
        throw CLIError("job \(job.jobId) is still \(job.status)")
    default:
        return .failed(job)
    }
}

func failure(_ job: JobSnapshot) -> CLIError {
    CLIError("job \(job.jobId) \(job.status): \(job.error?.message ?? "")")
}

func unexpected(_ output: JobOutput) -> CLIError {
    CLIError("daemon returned an unexpected result kind: \(output)")
}
