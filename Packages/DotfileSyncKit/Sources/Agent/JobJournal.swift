// Port of crates/dotfilesync-daemon/src/journal.rs: minimal durable job journal
// (`state/jobs.jsonl`, append-only JSON lines, metadata only).
//
// Records contain a job id, kind, lifecycle event and timestamp. They never contain job
// params, paths, results, config bodies, approval tokens or subprocess output.

import Core
import Foundation
import IPC
import Synchronization
import System

/// Jobs kept after startup compaction.
public let JOURNAL_RETAIN = 200
/// Lines longer than this are treated as corrupt.
let MAX_RECORD = 4096

/// Lifecycle events recorded in `jobs.jsonl`.
public enum JournalEvent: String, Codable, Sendable, Equatable {
    case started, succeeded, failed, cancelled, interrupted

    /// The terminal event for `status`, or `nil` for non-terminal statuses.
    public static func from(status: JobStatus) -> JournalEvent? {
        switch status {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted: return .interrupted
        default: return nil
        }
    }

    var status: JobStatus {
        switch self {
        case .started: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted: return .interrupted
        }
    }
}

/// One `jobs.jsonl` line: `{"job_id":…,"kind":…,"event":…,"at_ms":…}`.
public struct JournalRecord: Codable, Sendable, Equatable {
    public var jobId: String
    public var kind: JobKind
    public var event: JournalEvent
    public var atMs: UInt64

    public init(jobId: String, kind: JobKind, event: JournalEvent, atMs: UInt64) {
        self.jobId = jobId
        self.kind = kind
        self.event = event
        self.atMs = atMs
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case jobId = "job_id"
        case kind, event
        case atMs = "at_ms"
    }

    /// Decodes one line, rejecting unknown fields (serde `deny_unknown_fields`).
    static func decodeStrict(_ bytes: [UInt8]) -> JournalRecord? {
        let data = Data(bytes)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if !Set(object.keys).isSubset(of: allowed) {
            return nil
        }
        return try? JSONDecoder().decode(JournalRecord.self, from: data)
    }
}

/// A job reconstructed from a previous agent run.
public struct RecoveredJob: Sendable, Equatable {
    public var jobId: String
    public var kind: JobKind
    public var status: JobStatus
    public var createdAtMs: UInt64
    public var finishedAtMs: UInt64?
}

/// What ``JobJournal/openAndRecover(_:)`` found.
public struct RecoveryReport: Sendable, Equatable {
    public var jobs: [RecoveredJob] = []
    public var newlyInterrupted = 0
    public var corruptLines = 0
}

/// The `jobs.jsonl` journal. Writes are serialized by an internal mutex.
public final class JobJournal: Sendable {
    public let path: FilePath
    private let lock = Mutex(())

    private init(path: FilePath) {
        self.path = path
    }

    /// Loads the journal, marks unfinished jobs `interrupted`, and compacts it.
    public static func openAndRecover(_ path: FilePath) throws(AgentIOError) -> (JobJournal, RecoveryReport) {
        var report = RecoveryReport()
        var order: [String] = []
        var jobs: [String: RecoveredJob] = [:]

        do {
            let file = try openPrivateRead(path)
            let bytes = try file.readAll()
            for line in bytes.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast(bytes.last == 0x0A ? 1 : 0) {
                // Rust counts the newline toward MAX_RECORD (`read_until` keeps it).
                if line.count >= MAX_RECORD {
                    report.corruptLines += 1
                    continue
                }
                guard let rec = JournalRecord.decodeStrict(Array(line)) else {
                    report.corruptLines += 1
                    continue
                }
                if jobs[rec.jobId] == nil {
                    order.append(rec.jobId)
                    jobs[rec.jobId] = RecoveredJob(
                        jobId: rec.jobId, kind: rec.kind, status: .running,
                        createdAtMs: rec.atMs, finishedAtMs: nil
                    )
                }
                if rec.event != .started {
                    jobs[rec.jobId]?.status = rec.event.status
                    jobs[rec.jobId]?.finishedAtMs = rec.atMs
                }
            }
        } catch {
            if error.code != ENOENT {
                throw error
            }
        }

        let now = nowMs()
        for id in order {
            if let job = jobs[id], !job.status.isTerminal {
                jobs[id]?.status = .interrupted
                jobs[id]?.finishedAtMs = now
                report.newlyInterrupted += 1
            }
        }

        let keepFrom = max(0, order.count - JOURNAL_RETAIN)
        report.jobs = order[keepFrom...].compactMap { jobs[$0] }

        let journal = JobJournal(path: path)
        try journal.rewrite(report.jobs)
        return (journal, report)
    }

    private func rewrite(_ jobs: [RecoveredJob]) throws(AgentIOError) {
        try lock.withLock { _ throws(AgentIOError) in
            let tmp = FilePath(path.string + ".tmp")
            removeFile(tmp)
            var buf: [UInt8] = []
            for j in jobs {
                writeLine(&buf, JournalRecord(jobId: j.jobId, kind: j.kind, event: .started, atMs: j.createdAtMs))
                if let ev = JournalEvent.from(status: j.status) {
                    writeLine(&buf, JournalRecord(jobId: j.jobId, kind: j.kind, event: ev, atMs: j.finishedAtMs ?? j.createdAtMs))
                }
            }
            do {
                let f = try openPrivateFile(tmp, mode: .truncate)
                try f.writeAll(buf)
                try f.sync()
            }
            try renamePath(tmp, path)
        }
    }

    /// Appends one record (fsynced).
    public func append(jobId: String, kind: JobKind, event: JournalEvent) throws(AgentIOError) {
        var buf: [UInt8] = []
        writeLine(&buf, JournalRecord(jobId: jobId, kind: kind, event: event, atMs: nowMs()))
        try lock.withLock { _ throws(AgentIOError) in
            let f = try openPrivateFile(path, mode: .append)
            try f.writeAll(buf)
            try f.sync()
        }
    }
}

private func writeLine(_ buf: inout [UInt8], _ rec: JournalRecord) {
    let line = (try? jsonStringCompact(rec)) ?? ""
    buf.append(contentsOf: Array(line.utf8))
    buf.append(0x0A)
}
