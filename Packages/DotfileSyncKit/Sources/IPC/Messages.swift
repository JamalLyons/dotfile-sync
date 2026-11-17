// Port of crates/dotfilesync-protocol/src/messages.rs (typed messages only).
//
// The socket envelopes (`ClientHello`, `HelloAck`, `RequestFrame`, `ServerFrame`), framing,
// and peer credentials are not ported: XPC replaces that transport. The JSON form of every
// type here is byte-identical to serde's (via `jsonStringCompact`) so it stays a documented
// wire/debug format:
// - `Request`: `{"op": "<name>", "params": {...}}` (serde adjacent tagging).
// - `JobSpec` / `JobOutput` / `Notification`: internally tagged with `kind`.
// - `Response`: internally tagged with `response`.
// - `Outcome`: externally tagged (`{"ok": ...}` / `{"err": ...}`).

import Core
import Foundation
import System

/// Current protocol version. Bump on any incompatible message change.
public let PROTOCOL_VERSION: UInt32 = 1
/// Versions this build can speak.
public let SUPPORTED_VERSIONS: [UInt32] = [PROTOCOL_VERSION]

/// Every operation the agent implements, by wire name.
public let IMPLEMENTED_OPS: [String] = [
    "ping",
    "daemon_info",
    "start_job",
    "job_status",
    "list_jobs",
    "job_progress",
    "watch_job",
    "job_result",
    "cancel_job",
    "shutdown",
    "plan.create",
    "plan.approve",
    "plan.apply",
    "plan.resume",
    "plan.runs",
    "plan.run_status",
]

/// Operation namespaces reserved for later issues, answered with `unsupported_operation`.
public let RESERVED_OPS: [(prefix: String, why: String)] = [
    ("runtime.", "toolchain/runtime management arrives with issue #5"),
    ("config.", "config discovery and editing arrives with issue #11"),
    ("sync.", "GitHub state-repo sync arrives with issues #6 and #7"),
]

// MARK: - Requests

/// A typed request. All parameters are plain data; there is no variant carrying a command.
public enum Request: Codable, Sendable, Equatable {
    case ping
    case daemonInfo
    case startJob(spec: JobSpec)
    case jobStatus(jobId: String)
    case listJobs
    case jobProgress(jobId: String, sinceSeq: UInt64)
    case watchJob(jobId: String, sinceSeq: UInt64)
    case jobResult(jobId: String)
    case cancelJob(jobId: String)
    case shutdown
    case planCreate(input: PlanInput)
    case planApprove(planId: String, digest: String)
    case planApply(planId: String, token: String, allowSudo: Bool)
    case planResume(runId: String, token: String, allowSudo: Bool)
    case planRuns
    case planRunStatus(runId: String)

    /// The wire name of this operation (`IMPLEMENTED_OPS`).
    public var opName: String {
        switch self {
        case .ping: return "ping"
        case .daemonInfo: return "daemon_info"
        case .startJob: return "start_job"
        case .jobStatus: return "job_status"
        case .listJobs: return "list_jobs"
        case .jobProgress: return "job_progress"
        case .watchJob: return "watch_job"
        case .jobResult: return "job_result"
        case .cancelJob: return "cancel_job"
        case .shutdown: return "shutdown"
        case .planCreate: return "plan.create"
        case .planApprove: return "plan.approve"
        case .planApply: return "plan.apply"
        case .planResume: return "plan.resume"
        case .planRuns: return "plan.runs"
        case .planRunStatus: return "plan.run_status"
        }
    }

    private enum EnvelopeKeys: String, CodingKey {
        case op, params
    }

    private enum ParamKeys: String, CodingKey {
        case spec
        case jobId = "job_id"
        case sinceSeq = "since_seq"
        case input
        case planId = "plan_id"
        case digest
        case token
        case allowSudo = "allow_sudo"
        case runId = "run_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: EnvelopeKeys.self)
        try c.encode(opName, forKey: .op)
        var p = c.nestedContainer(keyedBy: ParamKeys.self, forKey: .params)
        switch self {
        case .ping, .daemonInfo, .listJobs, .shutdown, .planRuns:
            break
        case let .startJob(spec):
            try p.encode(spec, forKey: .spec)
        case let .jobStatus(jobId), let .jobResult(jobId), let .cancelJob(jobId):
            try p.encode(jobId, forKey: .jobId)
        case let .jobProgress(jobId, sinceSeq), let .watchJob(jobId, sinceSeq):
            try p.encode(jobId, forKey: .jobId)
            try p.encode(sinceSeq, forKey: .sinceSeq)
        case let .planCreate(input):
            try p.encode(input, forKey: .input)
        case let .planApprove(planId, digest):
            try p.encode(planId, forKey: .planId)
            try p.encode(digest, forKey: .digest)
        case let .planApply(planId, token, allowSudo):
            try p.encode(planId, forKey: .planId)
            try p.encode(token, forKey: .token)
            try p.encode(allowSudo, forKey: .allowSudo)
        case let .planResume(runId, token, allowSudo):
            try p.encode(runId, forKey: .runId)
            try p.encode(token, forKey: .token)
            try p.encode(allowSudo, forKey: .allowSudo)
        case let .planRunStatus(runId):
            try p.encode(runId, forKey: .runId)
        }
    }

    /// Decodes `{"op": ..., "params": ...}`. Missing or `null` params decode as `{}`.
    /// Prefer ``decode(json:)`` / ``decode(op:params:)``, which classify failures.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: EnvelopeKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        let hasParams = try c.contains(.params) && !c.decodeNil(forKey: .params)
        if !hasParams {
            switch op {
            case "ping": self = .ping
            case "daemon_info": self = .daemonInfo
            case "list_jobs": self = .listJobs
            case "shutdown": self = .shutdown
            case "plan.runs": self = .planRuns
            default:
                throw DecodingError.keyNotFound(
                    EnvelopeKeys.params,
                    .init(codingPath: c.codingPath, debugDescription: "missing params for '\(op)'")
                )
            }
            return
        }
        let p = try c.nestedContainer(keyedBy: ParamKeys.self, forKey: .params)
        switch op {
        case "ping": self = .ping
        case "daemon_info": self = .daemonInfo
        case "start_job": self = .startJob(spec: try p.decode(JobSpec.self, forKey: .spec))
        case "job_status": self = .jobStatus(jobId: try p.decode(String.self, forKey: .jobId))
        case "list_jobs": self = .listJobs
        case "job_progress":
            self = .jobProgress(
                jobId: try p.decode(String.self, forKey: .jobId),
                sinceSeq: try p.decode(UInt64.self, forKey: .sinceSeq)
            )
        case "watch_job":
            self = .watchJob(
                jobId: try p.decode(String.self, forKey: .jobId),
                sinceSeq: try p.decode(UInt64.self, forKey: .sinceSeq)
            )
        case "job_result": self = .jobResult(jobId: try p.decode(String.self, forKey: .jobId))
        case "cancel_job": self = .cancelJob(jobId: try p.decode(String.self, forKey: .jobId))
        case "shutdown": self = .shutdown
        case "plan.create": self = .planCreate(input: try p.decode(PlanInput.self, forKey: .input))
        case "plan.approve":
            self = .planApprove(
                planId: try p.decode(String.self, forKey: .planId),
                digest: try p.decode(String.self, forKey: .digest)
            )
        case "plan.apply":
            self = .planApply(
                planId: try p.decode(String.self, forKey: .planId),
                token: try p.decode(String.self, forKey: .token),
                allowSudo: try p.decodeIfPresent(Bool.self, forKey: .allowSudo) ?? false
            )
        case "plan.resume":
            self = .planResume(
                runId: try p.decode(String.self, forKey: .runId),
                token: try p.decode(String.self, forKey: .token),
                allowSudo: try p.decodeIfPresent(Bool.self, forKey: .allowSudo) ?? false
            )
        case "plan.runs": self = .planRuns
        case "plan.run_status": self = .planRunStatus(runId: try p.decode(String.self, forKey: .runId))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: c, debugDescription: "unknown variant `\(op)`"
            )
        }
    }

    /// Classifies `op` before decoding (Rust `Request::from_frame`): reserved namespaces give
    /// `unsupported_operation`, unknown names `unknown_operation`, bad params `invalid_params`.
    ///
    /// `params` is the JSON encoding of the params object, or `nil` when absent.
    public static func decode(op: String, params: Data?) throws(ProtocolError) -> Request {
        if let reserved = RESERVED_OPS.first(where: { op.hasPrefix($0.prefix) }) {
            throw ProtocolError(
                .unsupportedOperation,
                "operation '\(op)' is not supported by this daemon: \(reserved.why)"
            )
        }
        if !IMPLEMENTED_OPS.contains(op) {
            throw ProtocolError(.unknownOperation, "unknown operation '\(truncate(op, 64))'")
        }
        var body = Data("{\"op\":".utf8)
        body.append(Data(((try? jsonStringCompact(op)) ?? "\"\"").utf8))
        body.append(Data(",\"params\":".utf8))
        body.append(params ?? Data("null".utf8))
        body.append(Data("}".utf8))
        do {
            return try JSONDecoder().decode(Request.self, from: body)
        } catch {
            throw ProtocolError(.invalidParams, "invalid params for '\(op)': \(describeDecoding(error))")
        }
    }

    /// Decodes a whole `{"op": ..., "params": ...}` document with the same classification as
    /// ``decode(op:params:)``. A document without a string `op` is `malformed_request`.
    public static func decode(json: Data) throws(ProtocolError) -> Request {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: json)
        } catch {
            throw ProtocolError(.malformedRequest, "malformed request: \(describeDecoding(error))")
        }
        return try decode(op: envelope.op, params: envelope.params)
    }

    private struct Envelope: Decodable {
        var op: String
        var params: Data?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: EnvelopeKeys.self)
            op = try c.decode(String.self, forKey: .op)
            if try c.contains(.params) && !c.decodeNil(forKey: .params) {
                let value = try c.decode(AnyJSON.self, forKey: .params)
                params = Data(((try? jsonStringCompact(value)) ?? "null").utf8)
            } else {
                params = nil
            }
        }
    }
}

/// Rust `truncate`: at most `max` UTF-8 bytes on a character boundary, plus `…` when cut.
func truncate(_ s: String, _ max: Int) -> String {
    if s.utf8.count <= max {
        return s
    }
    var out = ""
    var used = 0
    for scalar in s.unicodeScalars {
        let len = String(scalar).utf8.count
        if used + len > max { break }
        out.unicodeScalars.append(scalar)
        used += len
    }
    return out + "…"
}

/// A short, single-line description of a decoding failure.
func describeDecoding(_ error: any Error) -> String {
    guard let error = error as? DecodingError else {
        return String(describing: error)
    }
    func path(_ ctx: DecodingError.Context) -> String {
        let p = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return p.isEmpty ? "" : " at '\(p)'"
    }
    switch error {
    case let .typeMismatch(type, ctx):
        return "invalid type, expected \(type)\(path(ctx))"
    case let .valueNotFound(type, ctx):
        return "missing value of type \(type)\(path(ctx))"
    case let .keyNotFound(key, ctx):
        return "missing field `\(key.stringValue)`\(path(ctx))"
    case let .dataCorrupted(ctx):
        return "\(ctx.debugDescription)\(path(ctx))"
    @unknown default:
        return String(describing: error)
    }
}

/// A typed job. There is deliberately no variant that carries a command, script or executable.
public enum JobSpec: Codable, Sendable, Equatable {
    case scan(ScanInput)
    case status(StatusInput)

    /// The job kind this spec produces.
    public var kind: JobKind {
        switch self {
        case .scan: return .scan
        case .status: return .status
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "scan": self = .scan(try ScanInput(from: decoder))
        case "status": self = .status(try StatusInput(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown variant `\(kind)`, expected `scan` or `status`"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .scan(input):
            try c.encode("scan", forKey: .kind)
            try input.encode(to: encoder)
        case let .status(input):
            try c.encode("status", forKey: .kind)
            try input.encode(to: encoder)
        }
    }
}

/// Kind of job. Unknown kinds recorded by a newer agent decode as ``unknown``.
public enum JobKind: String, Codable, Sendable, Hashable, CustomStringConvertible {
    case scan
    case status
    case plan
    case apply
    /// A kind recorded by a newer agent version; shown but not interpreted.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobKind(rawValue: raw) ?? .unknown
    }

    public var description: String { rawValue }
}

// MARK: - Responses

/// Result of handling a request: a response or a typed error (`{"ok": …}` / `{"err": …}`).
public enum Outcome: Codable, Sendable, Equatable {
    case ok(Response)
    case err(ProtocolError)

    private enum CodingKeys: String, CodingKey {
        case ok, err
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.ok) {
            self = .ok(try c.decode(Response.self, forKey: .ok))
        } else {
            self = .err(try c.decode(ProtocolError.self, forKey: .err))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ok(response): try c.encode(response, forKey: .ok)
        case let .err(error): try c.encode(error, forKey: .err)
        }
    }

    /// The response, or throws the error.
    public func get() throws(ProtocolError) -> Response {
        switch self {
        case let .ok(response): return response
        case let .err(error): throw error
        }
    }
}

/// A successful response. Encodes with a `response` tag.
public enum Response: Codable, Sendable, Equatable {
    case pong
    case daemonInfo(DaemonInfo)
    case job(JobSnapshot)
    case jobs([JobSnapshot])
    /// `truncated` is true when older events were dropped from the bounded buffer.
    case progress(job: JobSnapshot, events: [ProgressEvent], truncated: Bool)
    case jobResult(JobOutput)
    case shuttingDown
    case approval(ApprovalGrant)
    case runs([RunSummary])
    case run(RunView)

    private enum CodingKeys: String, CodingKey {
        case response, jobs, job, events, truncated, runs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .response)
        switch tag {
        case "pong": self = .pong
        case "daemon_info": self = .daemonInfo(try DaemonInfo(from: decoder))
        case "job": self = .job(try JobSnapshot(from: decoder))
        case "jobs": self = .jobs(try c.decode([JobSnapshot].self, forKey: .jobs))
        case "progress":
            self = .progress(
                job: try c.decode(JobSnapshot.self, forKey: .job),
                events: try c.decode([ProgressEvent].self, forKey: .events),
                truncated: try c.decode(Bool.self, forKey: .truncated)
            )
        case "job_result": self = .jobResult(try JobOutput(from: decoder))
        case "shutting_down": self = .shuttingDown
        case "approval": self = .approval(try ApprovalGrant(from: decoder))
        case "runs": self = .runs(try c.decode([RunSummary].self, forKey: .runs))
        case "run": self = .run(try RunView(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .response, in: c, debugDescription: "unknown variant `\(tag)`"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pong:
            try c.encode("pong", forKey: .response)
        case let .daemonInfo(info):
            try c.encode("daemon_info", forKey: .response)
            try info.encode(to: encoder)
        case let .job(job):
            try c.encode("job", forKey: .response)
            try job.encode(to: encoder)
        case let .jobs(jobs):
            try c.encode("jobs", forKey: .response)
            try c.encode(jobs, forKey: .jobs)
        case let .progress(job, events, truncated):
            try c.encode("progress", forKey: .response)
            try c.encode(job, forKey: .job)
            try c.encode(events, forKey: .events)
            try c.encode(truncated, forKey: .truncated)
        case let .jobResult(output):
            try c.encode("job_result", forKey: .response)
            try output.encode(to: encoder)
        case .shuttingDown:
            try c.encode("shutting_down", forKey: .response)
        case let .approval(grant):
            try c.encode("approval", forKey: .response)
            try grant.encode(to: encoder)
        case let .runs(runs):
            try c.encode("runs", forKey: .response)
            try c.encode(runs, forKey: .runs)
        case let .run(view):
            try c.encode("run", forKey: .response)
            try view.encode(to: encoder)
        }
    }
}

/// Single-use approval handed to the client that reviewed a digest. The token is secret:
/// callers must not log or journal it.
public struct ApprovalGrant: Codable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public var token: String
    public var expiresAtMs: UInt64

    public init(token: String, expiresAtMs: UInt64) {
        self.token = token
        self.expiresAtMs = expiresAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case expiresAtMs = "expires_at_ms"
    }

    /// Never reveals the token.
    public var description: String { "ApprovalGrant(token: <redacted>, expiresAtMs: \(expiresAtMs))" }
    public var debugDescription: String { description }
}

/// How a durable apply run looks to a client, including after an agent restart.
public enum RunViewStatus: String, Codable, Sendable, Hashable, CustomStringConvertible {
    case running
    case succeeded
    case failed
    case cancelled
    /// The agent stopped while this run still had unfinished steps. Resumable.
    case interrupted

    public var description: String { rawValue }
}

/// One entry of `plan.runs`.
public struct RunSummary: Codable, Sendable, Equatable {
    public var runId: String
    public var planId: String
    public var planDigest: String
    public var jobId: String
    public var status: RunViewStatus

    public init(runId: String, planId: String, planDigest: String, jobId: String, status: RunViewStatus) {
        self.runId = runId
        self.planId = planId
        self.planDigest = planDigest
        self.jobId = jobId
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case planId = "plan_id"
        case planDigest = "plan_digest"
        case jobId = "job_id"
        case status
    }
}

/// A run's journal plus the status a client needs after reconnecting or restarting.
public struct RunView: Codable, Sendable, Equatable {
    public var runId: String
    public var planDigest: String
    public var steps: [StepRecord]
    public var status: RunViewStatus
    public var planId: String
    public var jobId: String
    /// Set when the agent will refuse to resume this run because its stored plan cannot be
    /// trusted (`plan.resume` fails with this reason). Omitted from JSON when `nil`.
    public var notResumable: NotResumable?

    public init(
        runId: String,
        planDigest: String,
        steps: [StepRecord],
        status: RunViewStatus,
        planId: String,
        jobId: String,
        notResumable: NotResumable? = nil
    ) {
        self.runId = runId
        self.planDigest = planDigest
        self.steps = steps
        self.status = status
        self.planId = planId
        self.jobId = jobId
        self.notResumable = notResumable
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case planDigest = "plan_digest"
        case steps, status
        case planId = "plan_id"
        case jobId = "job_id"
        case notResumable = "not_resumable"
    }

    /// The run as a core ``RunJournal``.
    public var journal: RunJournal {
        RunJournal(runId: runId, planDigest: planDigest, steps: steps)
    }
}

/// Why a run cannot be resumed (`RunView.notResumable`).
public struct NotResumable: Codable, Sendable, Equatable {
    /// Stable code: `missing_plan_digest` or `plan_digest_mismatch`.
    public var reason: String
    public var message: String

    public init(reason: String, message: String) {
        self.reason = reason
        self.message = message
    }
}

/// Streamed while watching a job.
public enum Notification: Codable, Sendable, Equatable {
    case progress(jobId: String, event: ProgressEvent)
    /// Sent periodically during long watches so a transport can detect dead peers.
    case heartbeat

    private enum CodingKeys: String, CodingKey {
        case kind
        case jobId = "job_id"
        case event
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "progress":
            self = .progress(
                jobId: try c.decode(String.self, forKey: .jobId),
                event: try c.decode(ProgressEvent.self, forKey: .event)
            )
        case "heartbeat": self = .heartbeat
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown variant `\(kind)`"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .progress(jobId, event):
            try c.encode("progress", forKey: .kind)
            try c.encode(jobId, forKey: .jobId)
            try c.encode(event, forKey: .event)
        case .heartbeat:
            try c.encode("heartbeat", forKey: .kind)
        }
    }
}

/// Agent identity and load.
public struct DaemonInfo: Codable, Sendable, Equatable {
    public var daemonVersion: String
    public var protocolVersion: UInt32
    public var pid: UInt32
    public var uptimeMs: UInt64
    public var dataDir: FilePath
    public var activeJobs: Int
    public var retainedJobs: Int

    public init(
        daemonVersion: String,
        protocolVersion: UInt32,
        pid: UInt32,
        uptimeMs: UInt64,
        dataDir: FilePath,
        activeJobs: Int,
        retainedJobs: Int
    ) {
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.uptimeMs = uptimeMs
        self.dataDir = dataDir
        self.activeJobs = activeJobs
        self.retainedJobs = retainedJobs
    }

    private enum CodingKeys: String, CodingKey {
        case daemonVersion = "daemon_version"
        case protocolVersion = "protocol_version"
        case pid
        case uptimeMs = "uptime_ms"
        case dataDir = "data_dir"
        case activeJobs = "active_jobs"
        case retainedJobs = "retained_jobs"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daemonVersion = try c.decode(String.self, forKey: .daemonVersion)
        protocolVersion = try c.decode(UInt32.self, forKey: .protocolVersion)
        pid = try c.decode(UInt32.self, forKey: .pid)
        uptimeMs = try c.decode(UInt64.self, forKey: .uptimeMs)
        dataDir = FilePath(try c.decode(String.self, forKey: .dataDir))
        activeJobs = try c.decode(Int.self, forKey: .activeJobs)
        retainedJobs = try c.decode(Int.self, forKey: .retainedJobs)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(daemonVersion, forKey: .daemonVersion)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(pid, forKey: .pid)
        try c.encode(uptimeMs, forKey: .uptimeMs)
        try c.encode(dataDir.string, forKey: .dataDir)
        try c.encode(activeJobs, forKey: .activeJobs)
        try c.encode(retainedJobs, forKey: .retainedJobs)
    }
}

/// Job lifecycle state. Unknown statuses from a newer agent decode as ``unknown``.
public enum JobStatus: String, Codable, Sendable, Hashable, CustomStringConvertible {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    /// Started by a previous agent process that stopped before recording an outcome.
    /// Never replayed automatically.
    case interrupted
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobStatus(rawValue: raw) ?? .unknown
    }

    /// True for every status except `queued` and `running`.
    public var isTerminal: Bool {
        self != .queued && self != .running
    }

    public var description: String { rawValue }
}

/// Point-in-time view of a job.
public struct JobSnapshot: Codable, Sendable, Equatable {
    public var jobId: String
    public var kind: JobKind
    public var status: JobStatus
    public var createdAtMs: UInt64
    public var finishedAtMs: UInt64?
    /// Sequence number of the newest progress event (0 = none yet).
    public var latestSeq: UInt64
    public var cancelRequested: Bool
    /// True for jobs recovered from the journal of a previous agent process.
    public var fromPreviousRun: Bool
    public var error: JobError?

    public init(
        jobId: String,
        kind: JobKind,
        status: JobStatus,
        createdAtMs: UInt64,
        finishedAtMs: UInt64? = nil,
        latestSeq: UInt64,
        cancelRequested: Bool,
        fromPreviousRun: Bool,
        error: JobError? = nil
    ) {
        self.jobId = jobId
        self.kind = kind
        self.status = status
        self.createdAtMs = createdAtMs
        self.finishedAtMs = finishedAtMs
        self.latestSeq = latestSeq
        self.cancelRequested = cancelRequested
        self.fromPreviousRun = fromPreviousRun
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case kind, status
        case createdAtMs = "created_at_ms"
        case finishedAtMs = "finished_at_ms"
        case latestSeq = "latest_seq"
        case cancelRequested = "cancel_requested"
        case fromPreviousRun = "from_previous_run"
        case error
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        kind = try c.decode(JobKind.self, forKey: .kind)
        status = try c.decode(JobStatus.self, forKey: .status)
        createdAtMs = try c.decode(UInt64.self, forKey: .createdAtMs)
        finishedAtMs = try c.decodeIfPresent(UInt64.self, forKey: .finishedAtMs)
        latestSeq = try c.decode(UInt64.self, forKey: .latestSeq)
        cancelRequested = try c.decode(Bool.self, forKey: .cancelRequested)
        fromPreviousRun = try c.decode(Bool.self, forKey: .fromPreviousRun)
        error = try c.decodeIfPresent(JobError.self, forKey: .error)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jobId, forKey: .jobId)
        try c.encode(kind, forKey: .kind)
        try c.encode(status, forKey: .status)
        try c.encode(createdAtMs, forKey: .createdAtMs)
        try c.encodeIfPresent(finishedAtMs, forKey: .finishedAtMs)
        try c.encode(latestSeq, forKey: .latestSeq)
        try c.encode(cancelRequested, forKey: .cancelRequested)
        try c.encode(fromPreviousRun, forKey: .fromPreviousRun)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

/// Why a job did not succeed.
public struct JobError: Codable, Sendable, Equatable {
    public var code: JobErrorCode
    public var message: String

    public init(code: JobErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// Category of a job failure. Unknown codes decode as ``unknown``.
public enum JobErrorCode: String, Codable, Sendable, Hashable {
    case manifestLoad = "manifest_load"
    case cancelled
    case interrupted
    case `internal`
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobErrorCode(rawValue: raw) ?? .unknown
    }
}

/// One progress event of a job. `seq` starts at 1 and increases by 1.
public struct ProgressEvent: Codable, Sendable, Equatable {
    public var seq: UInt64
    public var atMs: UInt64
    public var stage: String
    public var message: String

    public init(seq: UInt64, atMs: UInt64, stage: String, message: String) {
        self.seq = seq
        self.atMs = atMs
        self.stage = stage
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case seq
        case atMs = "at_ms"
        case stage, message
    }
}

/// Result of a succeeded job. Encodes with a `kind` tag.
public enum JobOutput: Codable, Sendable, Equatable {
    case scan(report: ScanReport)
    case status(report: StatusReport)
    case plan(plan: Plan, planId: String)
    case apply(journal: RunJournal)

    private enum CodingKeys: String, CodingKey {
        case kind, report, plan
        case planId = "plan_id"
        case journal
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "scan": self = .scan(report: try c.decode(ScanReport.self, forKey: .report))
        case "status": self = .status(report: try c.decode(StatusReport.self, forKey: .report))
        case "plan":
            self = .plan(
                plan: try c.decode(Plan.self, forKey: .plan),
                planId: try c.decode(String.self, forKey: .planId)
            )
        case "apply": self = .apply(journal: try c.decode(RunJournal.self, forKey: .journal))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown variant `\(kind)`"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .scan(report):
            try c.encode("scan", forKey: .kind)
            try c.encode(report, forKey: .report)
        case let .status(report):
            try c.encode("status", forKey: .kind)
            try c.encode(report, forKey: .report)
        case let .plan(plan, planId):
            try c.encode("plan", forKey: .kind)
            try c.encode(plan, forKey: .plan)
            try c.encode(planId, forKey: .planId)
        case let .apply(journal):
            try c.encode("apply", forKey: .kind)
            try c.encode(journal, forKey: .journal)
        }
    }
}

/// Largest JSON request body an agent accepts (Rust `MAX_REQUEST_FRAME`).
public let MAX_REQUEST_BYTES = 64 * 1024
/// Largest JSON response body an agent sends (Rust `MAX_RESPONSE_FRAME`).
public let MAX_RESPONSE_BYTES = 16 * 1024 * 1024
