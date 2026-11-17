// Port of crates/dotfilesync-daemon/src/plans.rs: in-memory plan cache and on-disk apply runs.
//
// Plans live only in memory (bounded). Approvals are separate and never written here. Run
// directories under `state/runs` survive restart; `meta.json` records status but never an
// approval token.

import Core
import Foundation
import IPC
import Synchronization
import System

/// Plans kept in memory.
public let MAX_PLANS = 32

/// A computed plan plus the input and owner it was computed for.
public struct StoredPlan: Sendable, Equatable {
    public var plan: Plan
    public var input: PlanInput
    public var ownerUid: UInt32
}

/// Bounded FIFO of plans keyed by plan id.
public final class PlanStore: Sendable {
    private let plans = Mutex<[StoredPlan]>([])

    public init() {}

    /// Inserts `stored`, replacing a plan with the same id and evicting the oldest past the bound.
    public func insert(_ stored: StoredPlan) {
        let id = stored.plan.planId
        plans.withLock { plans in
            plans.removeAll { $0.plan.planId == id }
            while plans.count >= MAX_PLANS {
                plans.removeFirst()
            }
            plans.append(stored)
        }
    }

    /// The plan with `planId`, if still cached.
    public func get(_ planId: String) -> StoredPlan? {
        plans.withLock { $0.first { $0.plan.planId == planId } }
    }
}

/// `meta.json`: `{"run_id","plan_id","plan_digest","job_id","status"[,"profile"]}`.
struct RunMetaFile: Codable, Equatable {
    var runId: String
    var planId: String
    var planDigest: String
    var jobId: String
    var status: RunViewStatus
    var profile: String?

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case planId = "plan_id"
        case planDigest = "plan_digest"
        case jobId = "job_id"
        case status, profile
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runId, forKey: .runId)
        try c.encode(planId, forKey: .planId)
        try c.encode(planDigest, forKey: .planDigest)
        try c.encode(jobId, forKey: .jobId)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(profile, forKey: .profile)
    }
}

struct RunMeta: Sendable {
    var runId: String
    var dir: FilePath
    var planId: String
    var planDigest: String
    var jobId: String
    var status: RunViewStatus
    var profile: String?
    /// Set at recovery when the run's stored plan cannot be trusted for resume.
    var unrecoverable: RunUnrecoverable? = nil
}

/// Why a recovered run cannot be resumed.
enum RunUnrecoverable: Error, Sendable, Equatable {
    /// `plan.json` is missing or cannot be decoded.
    case planUnreadable
    /// `meta.json` records no plan digest, so the stored plan cannot be checked.
    case missingPlanDigest
    /// `plan.json` does not hash to the digest recorded when the run started.
    case planDigestMismatch

    /// Stable `details.reason` value.
    var reason: String {
        switch self {
        case .planUnreadable: return "plan_unreadable"
        case .missingPlanDigest: return "missing_plan_digest"
        case .planDigestMismatch: return "plan_digest_mismatch"
        }
    }

    var message: String {
        switch self {
        case .planUnreadable: return "its stored plan is missing or unreadable"
        case .missingPlanDigest: return "it has no recorded plan digest"
        case .planDigestMismatch: return "its stored plan does not match the recorded plan digest"
        }
    }
}

/// Durable apply runs under `state/runs`.
public final class RunIndex: Sendable {
    private let log: Logger
    private let inner = Mutex<[RunMeta]>([])

    private init(log: Logger) {
        self.log = log
    }

    /// Loads run directories left by a previous process. A run still marked `running` becomes
    /// `interrupted` because this process did not start it. Plans found in run dirs are added
    /// to `plans` so interrupted runs can be re-approved and resumed.
    public static func recover(runsDir: FilePath, log: Logger, plans: PlanStore, ownerUid: UInt32) -> RunIndex {
        let index = RunIndex(log: log)
        let entries: [FilePath]
        do {
            entries = try listDirectory(runsDir)
        } catch {
            log.warn("could not read runs directory: \(error)")
            return index
        }
        for dir in entries where isDirectory(dir) {
            switch loadRun(dir) {
            case var .success(meta):
                if meta.status == .running {
                    meta.status = .interrupted
                    do {
                        try writeMeta(meta)
                    } catch {
                        log.warn("could not mark run \(meta.runId) interrupted: \(error)")
                    }
                }
                switch storedFromDir(dir, meta, ownerUid) {
                case let .success(stored):
                    plans.insert(stored)
                case let .failure(why):
                    meta.unrecoverable = why
                    log.warn("run \(meta.runId.isEmpty ? dir.string : meta.runId) cannot be resumed: \(why.message)")
                }
                index.inner.withLock { $0.append(meta) }
            case let .failure(error):
                log.warn("skipping run dir \(dir.string): \(error.message)")
            }
        }
        return index
    }

    /// Points an existing run at a new worker. Used by `plan.resume`.
    public func attachJob(runId: String, jobId: String) {
        inner.withLock { runs in
            guard let i = runs.firstIndex(where: { $0.runId == runId }) else { return }
            runs[i].jobId = jobId
            runs[i].status = .running
            do {
                try writeMeta(runs[i])
            } catch {
                log.warn("could not attach job \(jobId) to run \(runId): \(error)")
            }
        }
    }

    /// Records a new run in `dir` (run id not yet known).
    public func begin(jobId: String, dir: FilePath, plan: Plan, input: PlanInput) {
        let meta = RunMeta(
            runId: "", dir: dir, planId: plan.planId, planDigest: plan.digest,
            jobId: jobId, status: .running, profile: input.profile
        )
        do {
            try writeMeta(meta)
        } catch {
            log.warn("could not write run metadata for job \(jobId): \(error)")
        }
        inner.withLock { $0.append(meta) }
    }

    /// Records the run id once the journal header exists.
    public func noteRunId(jobId: String, runId: String) {
        inner.withLock { runs in
            guard let i = runs.firstIndex(where: { $0.jobId == jobId }) else { return }
            if runs[i].runId == runId { return }
            runs[i].runId = runId
            do {
                try writeMeta(runs[i])
            } catch {
                log.warn("could not record run id for job \(jobId): \(error)")
            }
        }
    }

    /// Renames a pending directory to `<runs>/<run_id>` and records the terminal status.
    @discardableResult
    public func finish(jobId: String, status: RunViewStatus, runId: String?) -> FilePath? {
        inner.withLock { runs -> FilePath? in
            guard let i = runs.firstIndex(where: { $0.jobId == jobId }) else { return nil }
            if let runId, !runId.isEmpty {
                runs[i].runId = runId
            }
            if !runs[i].runId.isEmpty {
                let parent = runs[i].dir.removingLastComponent()
                if !parent.isEmpty {
                    let dest = parent.appending(runs[i].runId)
                    if runs[i].dir != dest && !pathExists(dest) {
                        do {
                            try renamePath(runs[i].dir, dest)
                            runs[i].dir = dest
                        } catch {
                            log.warn("could not rename run dir to \(dest.string): \(error)")
                        }
                    }
                }
            }
            runs[i].status = status
            do {
                try writeMeta(runs[i])
            } catch {
                log.warn("could not update run metadata for job \(jobId): \(error)")
            }
            return runs[i].dir
        }
    }

    /// Directory of the run with `runId`.
    public func dirForRun(_ runId: String) -> FilePath? {
        inner.withLock { $0.first { $0.runId == runId }?.dir }
    }

    /// Every run with a known id, sorted by run id.
    public func list() -> [RunSummary] {
        inner.withLock { runs in
            runs.filter { !$0.runId.isEmpty }
                .map {
                    RunSummary(runId: $0.runId, planId: $0.planId, planDigest: $0.planDigest, jobId: $0.jobId, status: $0.status)
                }
                .sorted { $0.runId < $1.runId }
        }
    }

    /// The run's current view (journal steps read from disk).
    public func get(_ runId: String) throws(ProtocolError) -> RunView {
        guard let meta = inner.withLock({ $0.first { $0.runId == runId } }) else {
            throw ProtocolError(.planNotFound, "no run with id '\(runId)'")
        }
        let (planDigest, steps): (String, [StepRecord])
        switch readJournal(meta.dir) {
        case let .success(j): (planDigest, steps) = (j.planDigest, j.steps)
        case .failure: (planDigest, steps) = (meta.planDigest, [])
        }
        return RunView(
            runId: meta.runId, planDigest: planDigest, steps: steps,
            status: meta.status, planId: meta.planId, jobId: meta.jobId,
            notResumable: meta.unrecoverable.map { NotResumable(reason: $0.reason, message: $0.message) }
        )
    }

    /// Why the run with `runId` cannot be resumed, if recovery found its stored plan untrusted.
    func unrecoverable(_ runId: String) -> RunUnrecoverable? {
        inner.withLock { $0.first { $0.runId == runId }?.unrecoverable }
    }

    /// True while a run with `runId` is marked running.
    public func isActive(_ runId: String) -> Bool {
        inner.withLock { $0.contains { $0.runId == runId && $0.status == .running } }
    }
}

struct RunLoadError: Error {
    var message: String
}

/// The run id from `<dir>/journal.jsonl`'s header, if present and non-empty.
func readRunId(_ dir: FilePath) -> String? {
    guard case let .success(j) = readJournal(dir), !j.runId.isEmpty else { return nil }
    return j.runId
}

private func decodePlan(_ bytes: [UInt8]) -> Plan? {
    try? JSONDecoder().decode(Plan.self, from: Data(bytes))
}

/// The run's stored plan, only when it hashes to the digest recorded when the run started.
/// Every run this agent writes records that digest (`RunIndex.begin` and the journal header),
/// so an empty one means the directory was not written by the agent and is not trusted.
private func storedFromDir(_ dir: FilePath, _ meta: RunMeta, _ ownerUid: UInt32) -> Result<StoredPlan, RunUnrecoverable> {
    guard let bytes = readFileBytes(dir.appending("plan.json")), let plan = decodePlan(bytes) else {
        return .failure(.planUnreadable)
    }
    if meta.planDigest.isEmpty {
        return .failure(.missingPlanDigest)
    }
    if plan.digest != meta.planDigest {
        return .failure(.planDigestMismatch)
    }
    let input = PlanInput(
        manifest: plan.manifestPath,
        home: plan.home,
        repoRoot: plan.repoRoot,
        profile: meta.profile ?? plan.profile
    )
    return .success(StoredPlan(plan: plan, input: input, ownerUid: ownerUid))
}

private func loadRun(_ dir: FilePath) -> Result<RunMeta, RunLoadError> {
    let metaPath = dir.appending("meta.json")
    if isRegularFile(metaPath) {
        guard let bytes = readFileBytes(metaPath) else {
            return .failure(RunLoadError(message: "read \(metaPath.string): unreadable"))
        }
        let file: RunMetaFile
        do {
            file = try JSONDecoder().decode(RunMetaFile.self, from: Data(bytes))
        } catch {
            return .failure(RunLoadError(message: "decode \(metaPath.string): \(error)"))
        }
        var meta = RunMeta(
            runId: file.runId, dir: dir, planId: file.planId, planDigest: file.planDigest,
            jobId: file.jobId, status: file.status, profile: file.profile
        )
        if meta.runId.isEmpty, let id = readRunId(dir) {
            meta.runId = id
        }
        return .success(meta)
    }
    switch readJournal(dir) {
    case let .failure(error):
        return .failure(error)
    case let .success(j):
        let planId = readFileBytes(dir.appending("plan.json")).flatMap(decodePlan)?.planId ?? ""
        return .success(RunMeta(
            runId: j.runId, dir: dir, planId: planId, planDigest: j.planDigest,
            jobId: "", status: statusFromSteps(j.steps, live: false), profile: nil
        ))
    }
}

private func statusFromSteps(_ steps: [StepRecord], live: Bool) -> RunViewStatus {
    if steps.contains(where: { $0.status == .failed }) {
        return .failed
    }
    var latest: [(String, StepStatus)] = []
    for step in steps {
        if let i = latest.firstIndex(where: { $0.0 == step.actionId }) {
            latest[i].1 = step.status
        } else {
            latest.append((step.actionId, step.status))
        }
    }
    let finished = !latest.isEmpty && latest.allSatisfy { $0.1 == .done || $0.1 == .skipped }
    if finished {
        return .succeeded
    }
    return live ? .running : .interrupted
}

private struct JournalContents {
    var runId: String
    var planDigest: String
    var steps: [StepRecord]
}

/// One `journal.jsonl` line (`event` = `header` | `step`).
private enum RunJournalLine: Decodable {
    case header(runId: String, planDigest: String)
    case step(StepRecord)

    private enum CodingKeys: String, CodingKey {
        case event
        case runId = "run_id"
        case planDigest = "plan_digest"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .event) {
        case "header":
            self = .header(
                runId: try c.decode(String.self, forKey: .runId),
                planDigest: try c.decode(String.self, forKey: .planDigest)
            )
        case "step":
            self = .step(try StepRecord(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .event, in: c, debugDescription: "unknown variant")
        }
    }
}

private func readJournal(_ dir: FilePath) -> Result<JournalContents, RunLoadError> {
    let path = dir.appending("journal.jsonl")
    guard let bytes = readFileBytes(path) else {
        return .failure(RunLoadError(message: "open \(path.string): cannot read"))
    }
    var runId: String?
    var planDigest: String?
    var steps: [StepRecord] = []
    let text = String(decoding: bytes, as: UTF8.self)
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            continue
        }
        let parsed: RunJournalLine
        do {
            parsed = try JSONDecoder().decode(RunJournalLine.self, from: Data(line.utf8))
        } catch {
            return .failure(RunLoadError(message: "journal line \(index + 1): \(error)"))
        }
        switch parsed {
        case let .header(id, digest):
            runId = id
            planDigest = digest
        case let .step(step):
            steps.append(step)
        }
    }
    guard let runId else {
        return .failure(RunLoadError(message: "journal is missing a header"))
    }
    guard let planDigest else {
        return .failure(RunLoadError(message: "journal is missing a plan digest"))
    }
    return .success(JournalContents(runId: runId, planDigest: planDigest, steps: steps))
}

private func writeMeta(_ meta: RunMeta) throws(AgentIOError) {
    if meta.dir.isEmpty {
        return
    }
    let file = RunMetaFile(
        runId: meta.runId, planId: meta.planId, planDigest: meta.planDigest,
        jobId: meta.jobId, status: meta.status, profile: meta.profile
    )
    let json: String
    do {
        json = try jsonStringCompact(file)
    } catch {
        throw AgentIOError("encode run metadata: \(error)")
    }
    let out = try openPrivateFile(meta.dir.appending("meta.json"), mode: .truncate)
    try out.writeAll(Array(json.utf8))
    try out.sync()
}
