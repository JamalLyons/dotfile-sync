// Port of crates/dotfilesync-core/src/apply/journal.rs.
//
// `journal.jsonl` holds one compact JSON object per line, appended and fsynced per write:
// `{"event":"header","run_id":…,"plan_digest":…}` then `{"event":"step",<StepRecord fields>}`
// (serde `#[serde(tag = "event", rename_all = "snake_case")]`). `plan.json` is the pretty
// plan (`serde_json::to_vec_pretty`, no trailing newline).

import Darwin
import Foundation
import System

/// One line of `journal.jsonl`.
enum JournalLine: Codable, Equatable {
    case header(runId: String, planDigest: String)
    case step(StepRecord)

    private enum CodingKeys: String, CodingKey {
        case event
        case runId = "run_id"
        case planDigest = "plan_digest"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let event = try c.decode(String.self, forKey: .event)
        switch event {
        case "header":
            self = .header(
                runId: try c.decode(String.self, forKey: .runId),
                planDigest: try c.decode(String.self, forKey: .planDigest)
            )
        case "step":
            self = .step(try StepRecord(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: c,
                debugDescription: "unknown variant `\(event)`, expected `header` or `step`"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .header(runId, planDigest):
            try c.encode("header", forKey: .event)
            try c.encode(runId, forKey: .runId)
            try c.encode(planDigest, forKey: .planDigest)
        case let .step(record):
            try c.encode("step", forKey: .event)
            try record.encode(to: encoder)
        }
    }
}

/// Append-only run journal at `<run_dir>/journal.jsonl`.
public struct JournalStore: Sendable {
    /// Path of `journal.jsonl`.
    public let path: FilePath

    /// Writes `<runDir>/plan.json`, then starts `<runDir>/journal.jsonl` with a header line.
    ///
    /// Fails if a journal already exists (a run must be resumed, not restarted).
    public static func create(
        runDir: FilePath,
        runId: String,
        planDigest: String,
        plan: Plan
    ) throws(ApplyError) -> JournalStore {
        let planPath = runDir.appending("plan.json")
        let body: String
        do {
            body = try jsonStringPretty(plan)
        } catch {
            throw .journal("failed to encode plan: \(error)")
        }
        do {
            try syncFile(planPath, bytes: Array(body.utf8))
        } catch {
            throw .journal(error.message)
        }
        let path = runDir.appending("journal.jsonl")
        if pathExists(path) {
            throw .journal(
                "journal already exists at '\(path.string)'; resume it instead of starting a new run"
            )
        }
        let store = JournalStore(path: path)
        try store.append(.header(runId: runId, planDigest: planDigest))
        return store
    }

    /// Opens an existing `<runDir>/journal.jsonl`.
    public static func open(runDir: FilePath) throws(ApplyError) -> JournalStore {
        let path = runDir.appending("journal.jsonl")
        if !isRegularFileFollowing(path) {
            throw .journal("journal not found at '\(path.string)'")
        }
        return JournalStore(path: path)
    }

    /// Reads the journal: the last header's run id and plan digest, and every step record in
    /// file order. Blank lines are ignored.
    public func load() throws(ApplyError) -> (runId: String, planDigest: String, steps: [StepRecord]) {
        let bytes: [UInt8]
        do {
            bytes = try readAllBytes(path)
        } catch {
            throw .journal("failed to read journal: \(error)")
        }
        var runId: String?
        var planDigest: String?
        var steps: [StepRecord] = []
        for (index, raw) in splitLines(bytes).enumerated() {
            guard let line = String(validating: raw, as: UTF8.self) else {
                throw .journal("failed to read journal line: stream did not contain valid UTF-8")
            }
            if rustTrim(line).isEmpty {
                continue
            }
            let parsed: JournalLine
            do {
                parsed = try JSONDecoder().decode(JournalLine.self, from: Data(raw))
            } catch {
                throw .journal("invalid journal line \(index + 1): \(error)")
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
            throw .journal("journal is missing a header")
        }
        guard let planDigest else {
            throw .journal("journal is missing a plan digest")
        }
        return (runId, planDigest, steps)
    }

    /// Appends one step record and fsyncs the journal.
    public func appendStep(_ step: StepRecord) throws(ApplyError) {
        try append(.step(step))
    }

    func append(_ line: JournalLine) throws(ApplyError) {
        let encoded: String
        do {
            encoded = try jsonStringCompact(line)
        } catch {
            throw .journal("failed to encode journal: \(error)")
        }
        let fd = path.withPlatformString { Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o666) }
        if fd < 0 {
            throw .journal("failed to open journal: \(OSIOError.current())")
        }
        defer { close(fd) }
        if let error = writeAll(fd, Array((encoded + "\n").utf8)) {
            throw .journal("failed to append journal: \(error)")
        }
        if let error = fullFsync(fd) {
            throw .journal("failed to fsync journal: \(error)")
        }
    }
}

/// Rust `BufRead::lines`: split on `\n`, strip one trailing `\r`, no final empty line.
private func splitLines(_ bytes: [UInt8]) -> [[UInt8]] {
    var lines: [[UInt8]] = []
    var current: [UInt8] = []
    for byte in bytes {
        if byte == UInt8(ascii: "\n") {
            if current.last == UInt8(ascii: "\r") { current.removeLast() }
            lines.append(current)
            current = []
        } else {
            current.append(byte)
        }
    }
    if !current.isEmpty {
        if current.last == UInt8(ascii: "\r") { current.removeLast() }
        lines.append(current)
    }
    return lines
}
