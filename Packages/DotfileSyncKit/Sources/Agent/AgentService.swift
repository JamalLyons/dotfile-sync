// Transport-neutral port of the request dispatch in crates/dotfilesync-daemon/src/server.rs.
//
// Not ported (replaced by XPC + SMAppService in the next step): the socket accept loop,
// connection limits, handshake/version negotiation, heartbeat writes, frame size handling on
// the wire, peer credentials and the flock single-instance lock. A transport authenticates the
// peer, then calls ``AgentService/handle(_:callerUid:)`` or ``AgentService/watch(jobId:sinceSeq:callerUid:send:)``.

import Core
import Darwin
import Foundation
import IPC
import Synchronization
import System

/// Agent version reported by `daemon_info`.
public let AGENT_VERSION = "0.1.0"

/// Configuration for an ``AgentService``.
public struct AgentConfig: Sendable {
    public var layout: DataLayout
    /// The agent owner's home directory, independent of request parameters and the data layout.
    public var home: FilePath
    /// Homebrew binary chosen by the agent owner at startup. Never taken from requests.
    public var brewBin: FilePath?
    public var jobs: JobLimits
    public var logMaxBytes: UInt64
    public var logKeep: Int
    /// How long ``AgentService/shutdown()`` waits for cancelled jobs.
    public var shutdownGrace: Duration
    /// Longest gap between notifications during ``AgentService/watch(jobId:sinceSeq:callerUid:send:)``.
    public var heartbeatInterval: Duration
    /// The user this agent serves. Requests from any other UID are refused.
    public var ownerUid: UInt32
    /// Asked before every approval token is issued (Touch ID or the login password).
    public var presence: any UserPresenceVerifier

    public init(
        layout: DataLayout,
        brewBin: FilePath? = nil,
        jobs: JobLimits = JobLimits(),
        logMaxBytes: UInt64 = 1024 * 1024,
        logKeep: Int = 3,
        shutdownGrace: Duration = .seconds(5),
        heartbeatInterval: Duration = .seconds(5),
        ownerUid: UInt32 = geteuid(),
        presence: any UserPresenceVerifier = LocalAuthenticationPresence(),
        home: FilePath = FilePath(NSHomeDirectory())
    ) {
        self.layout = layout
        self.home = home
        self.brewBin = brewBin
        self.jobs = jobs
        self.logMaxBytes = logMaxBytes
        self.logKeep = logKeep
        self.shutdownGrace = shutdownGrace
        self.heartbeatInterval = heartbeatInterval
        self.ownerUid = ownerUid
        self.presence = presence
    }
}

/// Why an ``AgentService`` could not start.
public enum AgentError: Error, Sendable, CustomStringConvertible {
    case path(PathError)
    case io(path: FilePath, message: String)

    public var description: String {
        switch self {
        case let .path(error): return error.description
        case let .io(path, message): return "i/o error on '\(path.string)': \(message)"
        }
    }
}

/// The agent: owns the job manager, plan cache, approvals and run history, and answers typed
/// requests. Thread-safe; every method may be called from any thread. Long-running work runs on
/// job threads, so a caller going away never cancels a job.
public final class AgentService: Sendable {
    public let config: AgentConfig
    /// Jobs from the previous process that this start marked `interrupted`.
    public let recoveredInterrupted: Int
    private let jobs: JobManager
    private let log: Logger
    private let configs: ConfigOperations
    private let started = ContinuousClock.now
    private let shutdownRequested = Monitor(false)
    private let stopped = Mutex<Int?>(nil)
    private let activeWatches = Atomic<Int>(0)

    /// Prepares private directories, opens the log, recovers the job journal and run history.
    public init(config: AgentConfig) throws(AgentError) {
        let layout = config.layout
        do {
            try layout.ensurePrivateDirs()
        } catch {
            throw .path(error)
        }
        let log: Logger
        do {
            log = try Logger(path: layout.logFile, maxBytes: config.logMaxBytes, keep: config.logKeep)
        } catch {
            throw .io(path: layout.logFile, message: error.message)
        }
        let (journal, recovery): (JobJournal, RecoveryReport)
        do {
            (journal, recovery) = try JobJournal.openAndRecover(layout.journal)
        } catch {
            throw .io(path: layout.journal, message: error.message)
        }
        if recovery.corruptLines > 0 {
            log.warn("journal: skipped \(recovery.corruptLines) corrupt line(s)")
        }
        if recovery.newlyInterrupted > 0 {
            log.warn("journal: \(recovery.newlyInterrupted) job(s) from the previous run were interrupted and will not be replayed")
        }
        let locks = ResourceLocks()
        jobs = JobManager(
            journal: journal,
            log: log,
            locks: locks,
            brewBin: config.brewBin,
            limits: config.jobs,
            recovered: recovery.jobs,
            paths: JobPaths(runsDir: layout.runsDir, backupsDir: layout.backupsDir, ownerUid: config.ownerUid, home: config.home),
            presence: config.presence
        )
        self.config = config
        self.log = log
        configs = ConfigOperations(config: config, locks: locks, log: log)
        recoveredInterrupted = recovery.newlyInterrupted
        log.info("dotfilesyncd \(AGENT_VERSION) started pid=\(getpid()) protocol=\(PROTOCOL_VERSION)")
    }

    // MARK: - Requests

    /// Handles one request on behalf of `callerUid` (default: the owner). A transport must pass
    /// the UID it authenticated; requests never carry one.
    ///
    /// `watch_job` blocks until the job is terminal and discards its notifications; transports
    /// should call ``watch(jobId:sinceSeq:callerUid:send:)`` instead to stream them.
    public func handle(_ request: Request, callerUid: UInt32? = nil) -> Outcome {
        if let refused = authorize(callerUid) {
            return .err(refused)
        }
        if case let .watchJob(jobId, sinceSeq) = request {
            return watch(jobId: jobId, sinceSeq: sinceSeq, callerUid: callerUid) { (_: IPC.Notification) in true }
                ?? .err(ProtocolError(.internal, "watch ended without a result"))
        }
        do {
            return .ok(try dispatch(request))
        } catch {
            return .err(error)
        }
    }

    /// Decodes a JSON request (`{"op": …, "params": …}`) and handles it. Bodies larger than
    /// `MAX_REQUEST_BYTES` are refused with `frame_too_large`; undecodable bodies with
    /// `malformed_request`; unknown, reserved or invalid ops as in ``Request/decode(op:params:)``.
    public func handle(json: Data, callerUid: UInt32? = nil) -> Outcome {
        if let refused = authorize(callerUid) {
            return .err(refused)
        }
        if json.count > MAX_REQUEST_BYTES {
            return .err(ProtocolError(
                .frameTooLarge,
                "frame of \(json.count) bytes exceeds the \(MAX_REQUEST_BYTES)-byte request limit"
            ))
        }
        do {
            return handle(try Request.decode(json: json), callerUid: callerUid)
        } catch {
            return .err(error)
        }
    }

    /// Streams progress for `jobId` from `sinceSeq` (Rust `watch_job`).
    ///
    /// Calls `send` with each new ``Notification/progress(jobId:event:)`` in order, and with
    /// ``Notification/heartbeat`` whenever `heartbeatInterval` passes without events. Returns the
    /// final `.ok(.job(snapshot))` once the job is terminal and every event was sent, or `.err`
    /// for an unknown job. When `send` returns `false` (the peer went away) the watch stops and
    /// returns `nil`; the job itself is untouched.
    public func watch(
        jobId: String,
        sinceSeq: UInt64,
        callerUid: UInt32? = nil,
        send: (IPC.Notification) -> Bool
    ) -> Outcome? {
        if let refused = authorize(callerUid) {
            return .err(refused)
        }
        let job: Job
        do {
            job = try jobs.get(jobId)
        } catch {
            return .err(error)
        }
        let limit = config.jobs.maxWatches
        if activeWatches.wrappingAdd(1, ordering: .relaxed).oldValue >= limit {
            activeWatches.subtract(1, ordering: .relaxed)
            return .err(ProtocolError(.busy, "too many jobs are being watched (limit \(limit)); stop a watch and try again"))
        }
        defer { activeWatches.subtract(1, ordering: .relaxed) }
        var since = sinceSeq
        while true {
            let batch = job.wait(since: since, timeout: config.heartbeatInterval)
            for event in batch.events {
                since = max(since, event.seq)
                if !send(.progress(jobId: jobId, event: event)) {
                    return nil
                }
            }
            if batch.job.status.isTerminal && batch.job.latestSeq <= since {
                return .ok(.job(batch.job))
            }
            if batch.events.isEmpty && !send(.heartbeat) {
                return nil
            }
        }
    }

    private func authorize(_ callerUid: UInt32?) -> ProtocolError? {
        guard let uid = callerUid, uid != config.ownerUid else { return nil }
        log.warn("rejected connection from uid \(uid)")
        return ProtocolError(.unauthorized, "only the user that owns this daemon may connect")
    }

    private func dispatch(_ request: Request) throws(ProtocolError) -> Response {
        let owner = config.ownerUid
        switch request {
        case .ping:
            return .pong
        case .daemonInfo:
            let (active, retained) = jobs.counts()
            let uptime = ContinuousClock.now - started
            let (s, atto) = uptime.components
            return .daemonInfo(DaemonInfo(
                daemonVersion: AGENT_VERSION,
                protocolVersion: PROTOCOL_VERSION,
                pid: UInt32(getpid()),
                uptimeMs: UInt64(max(0, s)) * 1000 + UInt64(max(0, atto)) / 1_000_000_000_000_000,
                dataDir: config.layout.root,
                activeJobs: active,
                retainedJobs: retained
            ))
        case let .startJob(spec):
            if isShutdownRequested {
                throw ProtocolError(.shuttingDown, "daemon is shutting down")
            }
            return .job(try jobs.start(spec))
        case let .jobStatus(jobId):
            return .job(try jobs.get(jobId).snapshot())
        case .listJobs:
            return .jobs(jobs.list())
        case let .jobProgress(jobId, sinceSeq):
            let batch = try jobs.get(jobId).wait(since: sinceSeq, timeout: .zero)
            return .progress(job: batch.job, events: batch.events, truncated: batch.truncated)
        case let .jobResult(jobId):
            return .jobResult(try jobs.result(jobId))
        case let .cancelJob(jobId):
            return .job(try jobs.cancel(jobId))
        case let .planCreate(input):
            return .job(try jobs.startPlan(input, ownerUid: owner))
        case let .planApprove(planId, digest):
            return .approval(try jobs.approve(planId: planId, digest: digest, approverUid: owner))
        case let .planApply(planId, token, allowSudo):
            return .job(try jobs.apply(planId: planId, token: token, allowSudo: allowSudo, callerUid: owner))
        case let .planResume(runId, token, allowSudo):
            return .job(try jobs.resume(runId: runId, token: token, allowSudo: allowSudo, callerUid: owner))
        case .planRuns:
            return .runs(jobs.listRuns())
        case let .planRunStatus(runId):
            return .run(try jobs.runStatus(runId))
        case let .configDiscover(home):
            return .configDiscovery(try configs.discover(home: home))
        case let .configTree(manifest, home, repoRoot, profile):
            return .configTree(try configs.tree(manifest: manifest, home: home, repoRoot: repoRoot, profile: profile))
        case let .configDiff(target, manifest, home, repoRoot, profile):
            return .configDiff(try configs.diff(target: target, manifest: manifest, home: home, repoRoot: repoRoot, profile: profile))
        case let .configOpen(path):
            return .configDocument(try configs.open(path: path))
        case let .configSave(path, text, version, force):
            return try editConfig(paths: [path]) { editor throws(EditorError) in
                try editor.save(path: path, text: text, expectedVersion: version, force: force)
            }
        case let .configCreate(path, text):
            return try editConfig(paths: [path]) { editor throws(EditorError) in
                try editor.create(path: path, text: text)
            }
        case let .configRename(from, to):
            return try editConfig(paths: [from, to]) { editor throws(EditorError) in
                try editor.rename(from: from, to: to)
            }
        case let .configPromote(input, targets):
            return .job(try startConfigPlan(input, change: .promote(targets: targets)))
        case let .configDemote(input, targets):
            return .job(try startConfigPlan(input, change: .demote(targets: targets)))
        case .shutdown:
            log.info("shutdown requested over IPC")
            requestShutdown()
            return .shuttingDown
        case .watchJob:
            throw ProtocolError(.internal, "watch_job is handled by watch()")
        }
    }

    private func editConfig(
        paths: [String],
        _ write: (ConfigEditor) throws(EditorError) -> EditorWriteReport
    ) throws(ProtocolError) -> Response {
        .configWrite(try configs.edit(paths: paths, write, shuttingDown: { self.isShutdownRequested }))
    }

    private func startConfigPlan(_ input: PlanInput, change: ManifestChange) throws(ProtocolError) -> JobSnapshot {
        guard !isShutdownRequested else {
            throw ProtocolError(.shuttingDown, "daemon is shutting down")
        }
        return try jobs.startManifestChange(input, change: change, ownerUid: config.ownerUid)
    }

    // MARK: - Shutdown

    /// True once a `shutdown` request (or ``requestShutdown()``) arrived.
    public var isShutdownRequested: Bool {
        shutdownRequested.withLock { $0 }
    }

    /// Marks the agent as shutting down: new jobs are refused. Does not stop running jobs;
    /// the host calls ``shutdown()`` for that.
    public func requestShutdown() {
        shutdownRequested.withLock { $0 = true }
        shutdownRequested.broadcast()
    }

    /// Blocks until shutdown is requested or `timeout` passes. Returns whether it was requested.
    public func waitForShutdownRequest(timeout: Duration) -> Bool {
        shutdownRequested.waitUntil(
            deadline: ContinuousClock.now + timeout,
            { $0 ? true : nil },
            onTimeout: { $0 }
        )
    }

    /// Stops accepting jobs, cancels active ones (killing their subprocesses) and waits up to
    /// `shutdownGrace`. Returns the number still running at the deadline, which the next start
    /// reports as `interrupted`. Idempotent: later calls return the first result.
    @discardableResult
    public func shutdown() -> Int {
        requestShutdown()
        return stopped.withLock { result in
            if let result {
                return result
            }
            log.info("shutdown requested; cancelling active jobs")
            let unfinished = jobs.shutdown(grace: config.shutdownGrace)
            if unfinished > 0 {
                log.warn("\(unfinished) job(s) did not stop within the grace period; they will be reported as interrupted")
            }
            log.info("dotfilesyncd stopped")
            result = unfinished
            return unfinished
        }
    }
}
