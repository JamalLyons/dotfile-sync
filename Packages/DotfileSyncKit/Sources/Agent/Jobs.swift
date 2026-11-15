// Port of crates/dotfilesync-daemon/src/jobs.rs: typed jobs on worker threads, progress,
// cancellation, retention, journaling, plans, approvals and apply runs.
//
// Each job runs core's synchronous operation on its own `Thread`, so jobs keep running when
// the caller that started them goes away. Blocking waits use `NSCondition` (see `Monitor`).

import Core
import Darwin
import Foundation
import IPC
import Synchronization
import System

/// Progress events retained per job.
public let MAX_EVENTS_PER_JOB = 256
let MAX_PATH_BYTES = 4096

/// Bounds on concurrent and retained jobs.
public struct JobLimits: Sendable, Equatable {
    public var maxActive: Int
    public var maxRetained: Int
    /// Per-subprocess deadline for the brew runner.
    public var commandTimeout: Duration
    /// Concurrent `watch_job` streams. Each one holds a request thread for as long as it runs.
    public var maxWatches: Int

    public init(maxActive: Int = 16, maxRetained: Int = 64, commandTimeout: Duration = .seconds(120), maxWatches: Int = 16) {
        self.maxActive = maxActive
        self.maxRetained = maxRetained
        self.commandTimeout = commandTimeout
        self.maxWatches = maxWatches
    }
}

struct JobState {
    var status: JobStatus = .queued
    var events: [ProgressEvent] = []
    var nextSeq: UInt64 = 1
    var finishedAtMs: UInt64?
    var error: JobError?
    var output: JobOutput?
}

/// Result of ``Job/wait(since:timeout:)``.
public struct JobProgressBatch: Sendable, Equatable {
    public var job: JobSnapshot
    public var events: [ProgressEvent]
    /// True when events newer than `since` were already dropped from the bounded buffer.
    public var truncated: Bool
}

/// One job: immutable identity plus monitor-protected state.
public final class Job: Sendable {
    public let id: String
    public let kind: JobKind
    public let createdAtMs: UInt64
    public let fromPreviousRun: Bool
    /// Shared with the brew runner, which kills its subprocess when set.
    let cancel = CancellationFlag()
    let state: Monitor<JobState>

    init(id: String, kind: JobKind) {
        self.id = id
        self.kind = kind
        createdAtMs = nowMs()
        fromPreviousRun = false
        state = Monitor(JobState())
    }

    init(recovered r: RecoveredJob) {
        id = r.jobId
        kind = r.kind
        createdAtMs = r.createdAtMs
        fromPreviousRun = true
        var st = JobState()
        st.status = r.status
        st.finishedAtMs = r.finishedAtMs
        if r.status == .interrupted {
            st.error = JobError(
                code: .interrupted,
                message: "the daemon stopped before this job finished; it was not resumed or replayed"
            )
        }
        state = Monitor(st)
    }

    private func snapshotLocked(_ st: JobState) -> JobSnapshot {
        JobSnapshot(
            jobId: id,
            kind: kind,
            status: st.status,
            createdAtMs: createdAtMs,
            finishedAtMs: st.finishedAtMs,
            latestSeq: st.nextSeq - 1,
            cancelRequested: cancel.isCancelled,
            fromPreviousRun: fromPreviousRun,
            error: st.error
        )
    }

    /// Current snapshot.
    public func snapshot() -> JobSnapshot {
        state.withLock { snapshotLocked($0) }
    }

    var status: JobStatus {
        state.withLock { $0.status }
    }

    func pushEvent(_ stage: String, _ message: String) {
        state.withLock { st in
            let seq = st.nextSeq
            st.nextSeq += 1
            st.events.append(ProgressEvent(seq: seq, atMs: nowMs(), stage: stage, message: message))
            if st.events.count > MAX_EVENTS_PER_JOB {
                st.events.removeFirst(st.events.count - MAX_EVENTS_PER_JOB)
            }
        }
        state.broadcast()
    }

    func setStatus(_ status: JobStatus) {
        state.withLock { $0.status = status }
        state.broadcast()
    }

    func finish(_ status: JobStatus, output: JobOutput?, error: JobError?) {
        state.withLock { st in
            st.status = status
            st.output = output
            st.error = error
            st.finishedAtMs = nowMs()
        }
        state.broadcast()
    }

    private static func eventsSince(_ st: JobState, _ since: UInt64) -> ([ProgressEvent], Bool) {
        let truncated = st.events.first.map { $0.seq > since &+ 1 && since < UInt64.max } ?? false
        return (st.events.filter { $0.seq > since }, truncated)
    }

    /// Waits up to `timeout` for events newer than `since` or a terminal status.
    /// `timeout == .zero` returns immediately (Rust `job_progress`).
    public func wait(since: UInt64, timeout: Duration) -> JobProgressBatch {
        let deadline = ContinuousClock.now + timeout
        return state.waitUntil(deadline: deadline, { st -> JobProgressBatch? in
            if st.nextSeq - 1 > since || st.status.isTerminal {
                let (events, truncated) = Self.eventsSince(st, since)
                return JobProgressBatch(job: snapshotLocked(st), events: events, truncated: truncated)
            }
            return nil
        }, onTimeout: { st in
            let (events, truncated) = Self.eventsSince(st, since)
            return JobProgressBatch(job: snapshotLocked(st), events: events, truncated: truncated)
        })
    }
}

private struct Registry {
    var jobs: [String: Job] = [:]
    var order: [String] = []
}

private enum Work: Sendable {
    case spec(JobSpec)
    case plan(input: PlanInput, ownerUid: UInt32)
    /// `resumeDir` set resumes the journal in that directory instead of starting a run.
    case apply(plan: Plan, input: PlanInput, allowSudo: Bool, resumeDir: FilePath?)
}

/// Paths and owner the job manager needs.
public struct JobPaths: Sendable {
    public var runsDir: FilePath
    public var backupsDir: FilePath
    public var ownerUid: UInt32

    public init(runsDir: FilePath, backupsDir: FilePath, ownerUid: UInt32) {
        self.runsDir = runsDir
        self.backupsDir = backupsDir
        self.ownerUid = ownerUid
    }
}

/// Owns every job, the plan cache, approvals and the run index.
public final class JobManager: Sendable {
    private let registry = Mutex(Registry())
    private let journal: JobJournal
    private let log: Logger
    private let locks: ResourceLocks
    private let brewBin: FilePath?
    private let limits: JobLimits
    private let accepting = Atomic<Bool>(true)
    private let plans: PlanStore
    private let approvals: ApprovalStore
    private let runs: RunIndex
    private let runsDir: FilePath
    private let backupsDir: FilePath
    private let presence: any UserPresenceVerifier
    /// True while a presence prompt is open.
    private let presencePrompt = Atomic<Bool>(false)

    public init(
        journal: JobJournal,
        log: Logger,
        locks: ResourceLocks,
        brewBin: FilePath?,
        limits: JobLimits,
        recovered: [RecoveredJob],
        paths: JobPaths,
        presence: any UserPresenceVerifier
    ) {
        var reg = Registry()
        // Keep the newest recovered jobs visible so clients can see what was interrupted.
        for r in recovered.suffix(limits.maxRetained) {
            reg.order.append(r.jobId)
            reg.jobs[r.jobId] = Job(recovered: r)
        }
        registry.withLock { $0 = reg }
        self.journal = journal
        self.log = log
        self.locks = locks
        self.brewBin = brewBin
        self.limits = limits
        let plans = PlanStore()
        self.plans = plans
        approvals = ApprovalStore()
        runs = RunIndex.recover(runsDir: paths.runsDir, log: log, plans: plans, ownerUid: paths.ownerUid)
        runsDir = paths.runsDir
        backupsDir = paths.backupsDir
        self.presence = presence
    }

    /// The job with `id`.
    public func get(_ id: String) throws(ProtocolError) -> Job {
        guard let job = registry.withLock({ $0.jobs[id] }) else {
            throw notFound(id)
        }
        return job
    }

    /// Snapshots of retained jobs, oldest first.
    public func list() -> [JobSnapshot] {
        let jobs = registry.withLock { reg in reg.order.compactMap { reg.jobs[$0] } }
        return jobs.map { $0.snapshot() }
    }

    /// `(active, retained)` job counts.
    public func counts() -> (active: Int, retained: Int) {
        let jobs = registry.withLock { Array($0.jobs.values) }
        return (jobs.filter { !$0.status.isTerminal }.count, jobs.count)
    }

    /// Starts a scan or status job.
    public func start(_ spec: JobSpec) throws(ProtocolError) -> JobSnapshot {
        try validateSpec(spec)
        return try spawn(spec.kind, .spec(spec))
    }

    /// Starts a plan job for `ownerUid`.
    public func startPlan(_ input: PlanInput, ownerUid: UInt32) throws(ProtocolError) -> JobSnapshot {
        try validatePlanInput(input)
        return try spawn(.plan, .plan(input: input, ownerUid: ownerUid))
    }

    /// Issues a single-use approval for `planId` if `digest` is its current digest and the
    /// owner confirms their presence. At most one presence prompt is open at a time.
    public func approve(planId: String, digest: String, approverUid: UInt32) throws(ProtocolError) -> ApprovalGrant {
        try validateTokenId("plan_id", planId)
        guard let stored = plans.get(planId) else {
            throw planNotFound(planId)
        }
        if digest != stored.plan.digest {
            throw approvalRejected(.planMismatch)
        }
        try confirmPresence(stored)
        let binding = approvalBinding(stored)
        let now = nowMs()
        let token: ApprovalToken
        do {
            token = try approvals.issue(binding, approverUid: approverUid, nowMs: now, ttlMs: APPROVAL_TTL_MS)
        } catch {
            throw approvalRejected(error)
        }
        let (sum, overflow) = now.addingReportingOverflow(APPROVAL_TTL_MS)
        let expiresAtMs = overflow ? UInt64.max : sum
        log.info("plan \(planId) approved uid=\(approverUid) expires_at_ms=\(expiresAtMs)")
        return ApprovalGrant(token: token.expose(), expiresAtMs: expiresAtMs)
    }

    private func confirmPresence(_ stored: StoredPlan) throws(ProtocolError) {
        guard presencePrompt.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else {
            throw ProtocolError(.busy, "another approval is waiting for Touch ID or the password")
        }
        defer { presencePrompt.store(false, ordering: .releasing) }
        let count = stored.plan.actions.count
        let reason = "apply \(count) dotfilesync change\(count == 1 ? "" : "s") to \(stored.input.home.string)"
        switch presence.confirmUserPresence(reason: reason) {
        case .confirmed:
            return
        case let .denied(message), let .unavailable(message):
            log.warn("plan \(stored.plan.digest.prefix(12)) approval refused: user presence not confirmed (\(message))")
            throw approvalRejected(.userPresence(message))
        }
    }

    /// Redeems `token` and starts applying `planId`.
    public func apply(planId: String, token: String, allowSudo: Bool, callerUid: UInt32) throws(ProtocolError) -> JobSnapshot {
        try validateTokenId("plan_id", planId)
        try validateToken(token)
        guard let stored = plans.get(planId) else {
            throw planNotFound(planId)
        }
        // Re-observe before redeeming. The worker checks again after it holds the locks.
        let current = try observeFingerprint(stored.input)
        do {
            try approvals.redeem(
                .fromClient(token), plan: approvalBinding(stored), callerUid: callerUid,
                currentState: current, nowMs: nowMs()
            )
        } catch {
            throw approvalRejected(error)
        }
        log.info("plan \(planId) approval redeemed for apply")
        return try spawn(.apply, .apply(plan: stored.plan, input: stored.input, allowSudo: allowSudo, resumeDir: nil))
    }

    /// Redeems `token` and resumes the interrupted, failed or cancelled run `runId`.
    public func resume(runId: String, token: String, allowSudo: Bool, callerUid: UInt32) throws(ProtocolError) -> JobSnapshot {
        try validateTokenId("run_id", runId)
        try validateToken(token)
        let view = try runs.get(runId)
        if view.status == .running || runs.isActive(runId) {
            throw ProtocolError(.busy, "run '\(runId)' is already in progress")
        }
        if view.status == .succeeded {
            throw invalid("run '\(runId)' already completed")
        }
        guard let stored = plans.get(view.planId) else {
            throw planNotFound(view.planId)
        }
        if stored.plan.digest != view.planDigest {
            throw approvalRejected(.planMismatch)
        }
        // A partial apply already changed the machine, so resume is bound to the fingerprint
        // captured when the plan was approved, not a fresh observation.
        do {
            try approvals.redeem(
                .fromClient(token), plan: approvalBinding(stored), callerUid: callerUid,
                currentState: stored.plan.stateFingerprint, nowMs: nowMs()
            )
        } catch {
            throw approvalRejected(error)
        }
        guard let dir = runs.dirForRun(runId) else {
            throw ProtocolError(.planNotFound, "no run with id '\(runId)'")
        }
        log.info("run \(runId) approval redeemed for resume")
        return try spawn(.apply, .apply(plan: stored.plan, input: stored.input, allowSudo: allowSudo, resumeDir: dir))
    }

    /// Known runs.
    public func listRuns() -> [RunSummary] {
        runs.list()
    }

    /// One run's view.
    public func runStatus(_ runId: String) throws(ProtocolError) -> RunView {
        try validateTokenId("run_id", runId)
        return try runs.get(runId)
    }

    private func spawn(_ kind: JobKind, _ work: Work) throws(ProtocolError) -> JobSnapshot {
        if !accepting.load(ordering: .sequentiallyConsistent) {
            throw ProtocolError(.shuttingDown, "daemon is shutting down")
        }
        let id = "j-" + randomHex(8)
        let job = Job(id: id, kind: kind)
        let maxActive = limits.maxActive
        let busy: Int? = registry.withLock { reg in
            let active = reg.jobs.values.filter { !$0.status.isTerminal }.count
            if active >= maxActive {
                return active
            }
            reg.order.append(id)
            reg.jobs[id] = job
            evictLocked(&reg)
            return nil
        }
        if let active = busy {
            throw ProtocolError(.busy, "\(active) jobs are already active (limit \(maxActive)); retry later")
        }
        do {
            try journal.append(jobId: id, kind: kind, event: .started)
        } catch {
            log.warn("journal append failed for job \(id): \(error)")
        }
        log.info("job \(id) kind=\(kind) started")

        let thread = Thread { [self] in
            runJob(job, work)
        }
        thread.name = "job-\(id)"
        thread.start()
        return job.snapshot()
    }

    private func evictLocked(_ reg: inout Registry) {
        while reg.order.count > limits.maxRetained {
            // Evict the oldest *terminal* job; active jobs are never dropped.
            guard let pos = reg.order.firstIndex(where: { reg.jobs[$0]?.status.isTerminal ?? true }) else {
                break
            }
            let id = reg.order.remove(at: pos)
            reg.jobs.removeValue(forKey: id)
        }
    }

    private func complete(_ job: Job, _ status: JobStatus, output: JobOutput? = nil, error: JobError? = nil) {
        job.finish(status, output: output, error: error)
        if let ev = JournalEvent.from(status: status) {
            do {
                try journal.append(jobId: job.id, kind: job.kind, event: ev)
            } catch {
                log.warn("journal append failed for job \(job.id): \(error)")
            }
        }
        log.info("job \(job.id) kind=\(job.kind) finished status=\(status)")
    }

    private func runJob(_ job: Job, _ work: Work) {
        switch work {
        case let .spec(spec):
            runSpec(job, spec)
        case let .plan(input, ownerUid):
            runPlanJob(job, input, ownerUid)
        case let .apply(plan, input, allowSudo, resumeDir):
            runApplyJob(job, plan, input, allowSudo, resumeDir)
        }
    }

    private func acquire(_ job: Job, _ reqs: [(ResourceKey, LockMode)]) -> LockGuard? {
        job.setStatus(.running)
        job.pushEvent("acquiring_locks", "Waiting for resource locks")
        do {
            return try locks.acquire(reqs) { job.cancel.isCancelled }
        } catch {
            complete(job, .cancelled, error: cancelledError())
            return nil
        }
    }

    private func runSpec(_ job: Job, _ spec: JobSpec) {
        guard let lockGuard = acquire(job, lockRequests(spec)) else { return }
        let runner = makeRunner(cancel: job.cancel)
        let isCancelled = { job.cancel.isCancelled }
        let progress: (OpStage) -> Void = { stage in job.pushEvent(stage.rawValue, stage.describe) }
        let result: Result<JobOutput, OpError>
        switch spec {
        case let .scan(input):
            do {
                result = .success(.scan(report: try runScan(input, runner: runner, progress: progress, isCancelled: isCancelled)))
            } catch {
                result = .failure(error)
            }
        case let .status(input):
            do {
                result = .success(.status(report: try Core.runStatus(input, runner: runner, progress: progress, isCancelled: isCancelled)))
            } catch {
                result = .failure(error)
            }
        }
        lockGuard.release()
        finishOp(job, result)
    }

    private func runPlanJob(_ job: Job, _ input: PlanInput, _ ownerUid: UInt32) {
        guard let lockGuard = acquire(job, [(.homebrew, .shared), (.manifest(input.manifest), .shared)]) else { return }
        let runner = makeRunner(cancel: job.cancel)
        let result: Result<JobOutput, OpError>
        do {
            let plan = try runPlan(
                input, runner: runner, hostname: currentHostname(),
                progress: { stage in job.pushEvent(stage.rawValue, stage.describe) },
                isCancelled: { job.cancel.isCancelled }
            )
            plans.insert(StoredPlan(plan: plan, input: input, ownerUid: ownerUid))
            result = .success(.plan(plan: plan, planId: plan.planId))
        } catch {
            result = .failure(error)
        }
        lockGuard.release()
        finishOp(job, result)
    }

    private func runApplyJob(_ job: Job, _ plan: Plan, _ input: PlanInput, _ allowSudo: Bool, _ resumeDir: FilePath?) {
        guard let lockGuard = acquire(job, [(.homebrew, .exclusive), (.home(plan.home), .exclusive)]) else { return }

        if resumeDir == nil {
            do {
                let current = try observeFingerprint(input)
                if current != plan.stateFingerprint {
                    lockGuard.release()
                    complete(job, .failed, error: JobError(
                        code: .internal,
                        message: "observed state changed after approval; re-plan and approve again"
                    ))
                    return
                }
            } catch {
                lockGuard.release()
                complete(job, .failed, error: JobError(code: .internal, message: error.message))
                return
            }
        }

        let runDir: FilePath
        if let dir = resumeDir {
            if let runId = readRunId(dir) {
                runs.attachJob(runId: runId, jobId: job.id)
            }
            runDir = dir
        } else {
            let dir = runsDir.appending("pending-\(job.id)")
            do {
                try ensurePrivateDir(dir)
            } catch {
                lockGuard.release()
                complete(job, .failed, error: JobError(code: .internal, message: error.description))
                return
            }
            runs.begin(jobId: job.id, dir: dir, plan: plan, input: input)
            runDir = dir
        }

        let ctx = ApplyContext(
            runner: makeRunner(cancel: job.cancel),
            backupRoot: backupsDir,
            runDir: runDir,
            allowSudo: allowSudo,
            now: { nowMs() }
        )
        let runs = self.runs
        let progress: (StepRecord) -> Void = { record in
            if let runId = readRunId(runDir) {
                runs.noteRunId(jobId: job.id, runId: runId)
            }
            job.pushEvent(stepStage(record.status), "\(record.actionId) \(record.error ?? "")")
        }
        let isCancelled = { job.cancel.isCancelled }
        let result: Result<RunJournal, ApplyError>
        do {
            if let dir = resumeDir {
                result = .success(try resumeRun(runDir: dir, plan: plan, context: ctx, progress: progress, isCancelled: isCancelled))
            } else {
                result = .success(try applyPlan(plan, context: ctx, progress: progress, isCancelled: isCancelled))
            }
        } catch {
            result = .failure(error)
        }
        lockGuard.release()

        if let runId = readRunId(runDir) {
            runs.noteRunId(jobId: job.id, runId: runId)
        }
        switch result {
        case let .success(journal) where isCancelled():
            runs.finish(jobId: job.id, status: .cancelled, runId: journal.runId)
            complete(job, .cancelled, error: cancelledError())
        case let .success(journal):
            runs.finish(jobId: job.id, status: .succeeded, runId: journal.runId)
            job.pushEvent("done", "Completed")
            complete(job, .succeeded, output: .apply(journal: journal))
        case let .failure(.cancelled(journal)):
            runs.finish(jobId: job.id, status: .cancelled, runId: journal.runId)
            complete(job, .cancelled, error: cancelledError())
        case let .failure(.stepFailed(actionId, message, journal)):
            runs.finish(jobId: job.id, status: .failed, runId: journal.runId)
            complete(job, .failed, error: JobError(code: .internal, message: "step \(actionId) failed: \(message)"))
        case let .failure(error):
            runs.finish(jobId: job.id, status: .failed, runId: readRunId(runDir))
            complete(job, .failed, error: JobError(code: .internal, message: error.description))
        }
    }

    private func finishOp(_ job: Job, _ result: Result<JobOutput, OpError>) {
        switch result {
        case .success where job.cancel.isCancelled:
            complete(job, .cancelled, error: cancelledError())
        case let .success(output):
            job.pushEvent("done", "Completed")
            complete(job, .succeeded, output: output)
        case .failure(.cancelled):
            complete(job, .cancelled, error: cancelledError())
        case let .failure(error):
            if case .manifest = error {
                complete(job, .failed, error: JobError(code: .manifestLoad, message: error.description))
            } else {
                complete(job, .failed, error: JobError(code: .internal, message: error.description))
            }
        }
    }

    private func makeRunner(cancel: CancellationFlag?) -> RealCommandRunner {
        var runner = RealCommandRunner(timeout: limits.commandTimeout)
        if let cancel {
            runner = runner.withCancellation(cancel)
        }
        if let brewBin {
            runner = runner.withBrewBinary(brewBin)
        }
        return runner
    }

    private func observeFingerprint(_ input: PlanInput) throws(ProtocolError) -> String {
        do {
            return try runPlan(input, runner: makeRunner(cancel: nil), hostname: currentHostname()).stateFingerprint
        } catch {
            throw opToProtocol(error)
        }
    }

    /// Requests cancellation of a non-terminal job (idempotent).
    public func cancel(_ id: String) throws(ProtocolError) -> JobSnapshot {
        let job = try get(id)
        if !job.status.isTerminal {
            job.cancel.cancel()
            job.pushEvent("cancel_requested", "Cancellation requested")
            log.info("job \(id) cancel requested")
        }
        return job.snapshot()
    }

    /// The output of a succeeded job, or a typed error.
    public func result(_ id: String) throws(ProtocolError) -> JobOutput {
        let job = try get(id)
        let (status, output, error) = job.state.withLock { ($0.status, $0.output, $0.error) }
        switch (status, output) {
        case let (.succeeded, out?):
            return out
        case (.succeeded, nil):
            throw ProtocolError(.internal, "job succeeded but its result is no longer available")
        case let (s, _) where !s.isTerminal:
            throw ProtocolError(.jobNotFinished, "job '\(id)' is still \(s)")
        case let (s, _):
            throw ProtocolError(.jobFailed, "job '\(id)' \(s)\(error.map { ": \($0.message)" } ?? "")")
        }
    }

    /// Stops accepting jobs, cancels active ones, and waits up to `grace` for them to finish.
    /// Returns how many were still active at the deadline; the journal leaves those as
    /// started-without-outcome, so the next start reports them `interrupted`.
    public func shutdown(grace: Duration) -> Int {
        accepting.store(false, ordering: .sequentiallyConsistent)
        let active = registry.withLock { reg in reg.jobs.values.filter { !$0.status.isTerminal } }
        for job in active {
            job.cancel.cancel()
            job.pushEvent("cancel_requested", "Daemon shutting down")
        }
        let deadline = ContinuousClock.now + grace
        for job in active {
            let remaining = deadline - ContinuousClock.now
            _ = job.wait(since: UInt64.max, timeout: remaining > .zero ? remaining : .zero)
        }
        return active.filter { !$0.status.isTerminal }.count
    }

    /// True until ``shutdown(grace:)`` runs.
    public var isAccepting: Bool {
        accepting.load(ordering: .sequentiallyConsistent)
    }
}

private func notFound(_ id: String) -> ProtocolError {
    ProtocolError(.jobNotFound, "no job with id '\(id)'")
}

private func invalid(_ message: String) -> ProtocolError {
    ProtocolError(.invalidParams, message)
}

func validatePath(_ name: String, _ p: FilePath) throws(ProtocolError) {
    let bytes = p.withPlatformString { strlen($0) }
    let raw = p.string.utf8.count
    if raw == 0 || raw > MAX_PATH_BYTES {
        throw invalid("'\(name)' must be 1..=\(MAX_PATH_BYTES) bytes")
    }
    if !p.isAbsolute {
        throw invalid("'\(name)' must be an absolute path")
    }
    if bytes != raw || p.string.utf8.contains(0) {
        throw invalid("'\(name)' must not contain NUL bytes")
    }
}

private func validateSpec(_ spec: JobSpec) throws(ProtocolError) {
    switch spec {
    case let .scan(s):
        if let m = s.manifest { try validatePath("manifest", m) }
        try validatePath("home", s.home)
        if let r = s.repoRoot { try validatePath("repo_root", r) }
    case let .status(s):
        try validatePath("manifest", s.manifest)
        try validatePath("home", s.home)
        if let r = s.repoRoot { try validatePath("repo_root", r) }
    }
}

private func lockRequests(_ spec: JobSpec) -> [(ResourceKey, LockMode)] {
    var reqs: [(ResourceKey, LockMode)] = [(.homebrew, .shared)]
    switch spec {
    case let .scan(s):
        if let m = s.manifest { reqs.append((.manifest(m), .shared)) }
    case let .status(s):
        reqs.append((.manifest(s.manifest), .shared))
    }
    return reqs
}

private func stepStage(_ status: StepStatus) -> String {
    status.rawValue
}

private func validatePlanInput(_ input: PlanInput) throws(ProtocolError) {
    try validatePath("manifest", input.manifest)
    try validatePath("home", input.home)
    if let repo = input.repoRoot {
        try validatePath("repo_root", repo)
    }
    if let profile = input.profile {
        if profile.isEmpty || profile.utf8.count > 128
            || profile.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == "/" || $0 == "\\" })
        {
            throw invalid("profile name is invalid")
        }
    }
}

private func validateTokenId(_ name: String, _ id: String) throws(ProtocolError) {
    let ok = !id.isEmpty && id.utf8.count <= 80
        && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
    if !ok {
        throw invalid("'\(name)' must be 1..=80 ascii letters, digits, or '-'")
    }
}

private func validateToken(_ token: String) throws(ProtocolError) {
    if token.isEmpty || token.utf8.count > 256
        || token.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    {
        throw invalid("approval token is invalid")
    }
}

private func approvalBinding(_ stored: StoredPlan) -> ApprovalPlan {
    ApprovalPlan(
        planId: stored.plan.planId,
        resource: "home:\(stored.plan.home.string)",
        contentDigest: stored.plan.digest,
        stateFingerprint: stored.plan.stateFingerprint,
        ownerUid: stored.ownerUid
    )
}

func approvalRejected(_ error: ApprovalError) -> ProtocolError {
    ProtocolError(.approvalRejected, error.description)
        .withDetails(.object([("reason", .string(error.reason))]))
}

private func planNotFound(_ id: String) -> ProtocolError {
    ProtocolError(.planNotFound, "no plan with id '\(id)'")
}

private func opToProtocol(_ error: OpError) -> ProtocolError {
    switch error {
    case .cancelled:
        return ProtocolError(.internal, "planning was cancelled")
    case .manifest:
        return ProtocolError(.invalidParams, error.description)
    case let .failed(message):
        return ProtocolError(.internal, message)
    }
}

private func cancelledError() -> JobError {
    JobError(code: .cancelled, message: "job was cancelled; no partial result is reported")
}
