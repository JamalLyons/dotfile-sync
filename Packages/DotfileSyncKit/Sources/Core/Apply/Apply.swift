// Port of crates/dotfilesync-core/src/apply/mod.rs.
//
// Applies a ``Plan`` one step at a time, journaling each transition: a `running` record is
// appended (and fsynced) before a step executes and a `done`/`skipped`/`failed` record after.
// Resume reloads the journal, refuses a plan whose digest differs, and re-runs every step whose
// latest record is not `done` or `skipped`.

import CryptoKit
import Darwin
import Foundation
import System

/// Fixed Fisher install script from `lib/fish.sh` (`fish -c` argument, not caller input).
let fisherInstallScript =
    "curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher"

/// Fixed `fisher update` script from `lib/fish.sh`.
let fisherUpdateScript = "type -q fisher; and fisher update"

let localOverrideStub = """
    # Local / private Fish environment variables (not managed by setup re-runs)
    # Add: set -gx MY_VAR "value"

    """

let sudoRequired = "requires sudo; rerun with --allow-sudo"

/// Runtime handles for one apply or resume.
public struct ApplyContext: Sendable {
    public var runner: any CommandRunner
    public var backupRoot: FilePath
    /// Directory that holds `journal.jsonl` and `plan.json`.
    public var runDir: FilePath
    public var allowSudo: Bool
    /// Current time in Unix milliseconds.
    public var now: @Sendable () -> UInt64

    public init(
        runner: any CommandRunner,
        backupRoot: FilePath,
        runDir: FilePath,
        allowSudo: Bool,
        now: @escaping @Sendable () -> UInt64
    ) {
        self.runner = runner
        self.backupRoot = backupRoot
        self.runDir = runDir
        self.allowSudo = allowSudo
        self.now = now
    }
}

/// Lifecycle of one step. Encodes as a snake_case string.
public enum StepStatus: String, Codable, Sendable, Hashable {
    case pending
    case running
    case done
    case failed
    case skipped
}

/// One journaled step transition.
public struct StepRecord: Codable, Sendable, Equatable {
    public var actionId: String
    public var status: StepStatus
    public var backupPath: FilePath?
    public var error: String?
    public var atMs: UInt64
    /// Previous login shell captured before `chsh`, when this step changed it.
    public var previousShell: String?

    public init(
        actionId: String,
        status: StepStatus,
        backupPath: FilePath? = nil,
        error: String? = nil,
        atMs: UInt64,
        previousShell: String? = nil
    ) {
        self.actionId = actionId
        self.status = status
        self.backupPath = backupPath
        self.error = error
        self.atMs = atMs
        self.previousShell = previousShell
    }

    private enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case status
        case backupPath = "backup_path"
        case error
        case atMs = "at_ms"
        case previousShell = "previous_shell"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actionId = try c.decode(String.self, forKey: .actionId)
        status = try c.decode(StepStatus.self, forKey: .status)
        backupPath = try c.decodeIfPresent(String.self, forKey: .backupPath).map { FilePath($0) }
        error = try c.decodeIfPresent(String.self, forKey: .error)
        atMs = try c.decode(UInt64.self, forKey: .atMs)
        previousShell = try c.decodeIfPresent(String.self, forKey: .previousShell)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actionId, forKey: .actionId)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(backupPath?.string, forKey: .backupPath)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(atMs, forKey: .atMs)
        try c.encodeIfPresent(previousShell, forKey: .previousShell)
    }

    static func pending(_ actionId: String) -> StepRecord {
        StepRecord(actionId: actionId, status: .pending, atMs: 0)
    }
}

/// Snapshot of a run: its id, the digest of the plan it applies, and one record per action.
public struct RunJournal: Codable, Sendable, Equatable {
    public var runId: String
    public var planDigest: String
    public var steps: [StepRecord]

    public init(runId: String, planDigest: String, steps: [StepRecord]) {
        self.runId = runId
        self.planDigest = planDigest
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case planDigest = "plan_digest"
        case steps
    }
}

/// Failure of ``applyPlan(_:context:progress:isCancelled:)`` or
/// ``resumeRun(runDir:plan:context:progress:isCancelled:)``.
/// `description` matches the Rust `Display` strings.
public enum ApplyError: Error, Sendable, Equatable, CustomStringConvertible {
    case cancelled(journal: RunJournal)
    case digestMismatch(found: String, expected: String)
    case journal(String)
    case stepFailed(actionId: String, message: String, journal: RunJournal)

    public var description: String {
        switch self {
        case .cancelled:
            return "operation was cancelled"
        case let .digestMismatch(found, expected):
            return "plan digest mismatch: journal has \(found), plan is \(expected)"
        case let .journal(message):
            return message
        case let .stepFailed(actionId, message, _):
            return "step \(actionId) failed: \(message)"
        }
    }
}

private struct Outcome {
    var status: StepStatus
    var backupPath: FilePath?
    var previousShell: String?

    static let done = Outcome(status: .done)

    init(status: StepStatus, backupPath: FilePath? = nil, previousShell: String? = nil) {
        self.status = status
        self.backupPath = backupPath
        self.previousShell = previousShell
    }
}

/// Starts a new run of `plan`: writes `plan.json` and a fresh journal under
/// `context.runDir`, then executes every action in order.
public func applyPlan(
    _ plan: Plan,
    context ctx: ApplyContext,
    progress: (StepRecord) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
) throws(ApplyError) -> RunJournal {
    let digest = plan.digest
    let runId = makeRunId(digest: digest, now: ctx.now())
    do {
        try ensureDir(ctx.runDir)
        try ensureDir(ctx.backupRoot)
    } catch {
        throw .journal(error.message)
    }
    let store = try JournalStore.create(runDir: ctx.runDir, runId: runId, planDigest: digest, plan: plan)
    let pending = plan.actions.map { StepRecord.pending($0.id) }
    return try drive(plan, ctx, store, runId, digest, pending, progress, isCancelled)
}

/// Continues the run journaled in `runDir`. `plan` must have the journaled digest.
///
/// Each action takes its latest journaled record; actions without one start `pending`.
/// Steps already `done` or `skipped` are not re-run.
public func resumeRun(
    runDir: FilePath,
    plan: Plan,
    context ctx: ApplyContext,
    progress: (StepRecord) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
) throws(ApplyError) -> RunJournal {
    let store = try JournalStore.open(runDir: runDir)
    let (runId, digest, previous) = try store.load()
    let expected = plan.digest
    if digest != expected {
        throw .digestMismatch(found: digest, expected: expected)
    }
    let steps = plan.actions.map { action in
        previous.last(where: { $0.actionId == action.id }) ?? StepRecord.pending(action.id)
    }
    return try drive(plan, ctx, store, runId, digest, steps, progress, isCancelled)
}

private func drive(
    _ plan: Plan,
    _ ctx: ApplyContext,
    _ store: JournalStore,
    _ runId: String,
    _ digest: String,
    _ initial: [StepRecord],
    _ progress: (StepRecord) -> Void,
    _ isCancelled: () -> Bool
) throws(ApplyError) -> RunJournal {
    var steps = initial
    for index in plan.actions.indices {
        if isCancelled() {
            throw .cancelled(journal: RunJournal(runId: runId, planDigest: digest, steps: steps))
        }
        if steps[index].status == .done || steps[index].status == .skipped {
            continue
        }
        let running = StepRecord(actionId: plan.actions[index].id, status: .running, atMs: ctx.now())
        try store.appendStep(running)
        steps[index] = running
        progress(running)

        let record: StepRecord
        switch execute(plan.actions[index].kind, plan, ctx, runId) {
        case let .success(outcome):
            record = StepRecord(
                actionId: running.actionId,
                status: outcome.status,
                backupPath: outcome.backupPath,
                atMs: ctx.now(),
                previousShell: outcome.previousShell
            )
        case let .failure(error):
            record = StepRecord(
                actionId: running.actionId, status: .failed, error: error.message, atMs: ctx.now()
            )
        }
        try store.appendStep(record)
        steps[index] = record
        progress(record)
        if record.status == .failed {
            throw .stepFailed(
                actionId: record.actionId,
                message: record.error ?? "",
                journal: RunJournal(runId: runId, planDigest: digest, steps: steps)
            )
        }
    }
    return RunJournal(runId: runId, planDigest: digest, steps: steps)
}

private func execute(
    _ kind: ActionKind,
    _ plan: Plan,
    _ ctx: ApplyContext,
    _ runId: String
) -> Result<Outcome, ApplyIOError> {
    do throws(ApplyIOError) {
        switch kind {
        case let .brewInstallFormula(name):
            try brew(ctx, ["install", name])
            return .success(.done)
        case let .brewInstallCask(name):
            try brew(ctx, ["install", "--cask", name])
            return .success(.done)
        case let .copyFile(source, target):
            try refuseManagedTarget(plan, target)
            let backupPath = try backupIfPresent(plan, ctx, runId, target)
            let bytes: [UInt8]
            do {
                bytes = try readAllBytes(source)
            } catch {
                throw ApplyIOError("failed to read source '\(source.string)': \(error)")
            }
            let mode = fileMode(source) ?? 0o644
            try writeAtomic(target, bytes: bytes, mode: mode)
            return .success(Outcome(status: .done, backupPath: backupPath))
        case let .linkFile(source, target):
            try refuseManagedTarget(plan, target)
            let backupPath = try backupIfPresent(plan, ctx, runId, target)
            if let parent = rustParent(target) {
                try ensureDir(parent)
            }
            let result = source.withPlatformString { src in
                target.withPlatformString { dst in symlink(src, dst) }
            }
            if result != 0 {
                throw ApplyIOError("failed to symlink '\(target.string)': \(OSIOError.current())")
            }
            return .success(Outcome(status: .done, backupPath: backupPath))
        case let .ensureLocalOverride(target, template):
            if pathPresent(target) {
                return .success(Outcome(status: .skipped))
            }
            var bytes = Array(localOverrideStub.utf8)
            if let template, isRegularFileFollowing(template) {
                do {
                    bytes = try readAllBytes(template)
                } catch {
                    throw ApplyIOError(
                        "failed to read override template '\(template.string)': \(error)"
                    )
                }
            }
            try writeAtomic(target, bytes: bytes, mode: 0o644)
            return .success(.done)
        case .installFisher:
            try runProgram(ctx.runner, "fish", ["-c", fisherInstallScript])
            return .success(.done)
        case .fisherUpdate:
            try runProgram(ctx.runner, "fish", ["-c", fisherUpdateScript])
            return .success(.done)
        case let .setLoginShell(shell):
            return .success(try setLoginShell(ctx, shell))
        }
    } catch {
        return .failure(error)
    }
}

private func brew(_ ctx: ApplyContext, _ args: [String]) throws(ApplyIOError) {
    guard let brewPath = ctx.runner.findExecutable("brew") else {
        throw ApplyIOError("Homebrew executable ('brew') not found")
    }
    guard let program = String(validatingUTF8Path: brewPath) else {
        throw ApplyIOError("brew path '\(brewPath.string)' is not valid UTF-8")
    }
    try runProgram(ctx.runner, program, args)
}

private func runProgram(_ runner: any CommandRunner, _ program: String, _ args: [String]) throws(ApplyIOError) {
    do {
        _ = try runner.run(program, args: args)
    } catch {
        throw ApplyIOError(error.description)
    }
}

private func backupIfPresent(
    _ plan: Plan,
    _ ctx: ApplyContext,
    _ runId: String,
    _ target: FilePath
) throws(ApplyIOError) -> FilePath? {
    guard pathPresent(target) else { return nil }
    return try backupExisting(
        home: plan.home, backupRoot: ctx.backupRoot, runId: runId, target: target, nowMs: ctx.now()
    )
}

/// Re-checks the manifest at apply time: never replace `local.fish`, a machine override, or
/// an excluded path (exact path or glob on the full path or file name).
private func refuseManagedTarget(_ plan: Plan, _ target: FilePath) throws(ApplyIOError) {
    if rustFileName(target) == Array("local.fish".utf8) {
        throw ApplyIOError("refusing to replace local override '\(target.string)'")
    }
    let manifest: Manifest
    do {
        manifest = try loadManifest(plan.manifestPath.string)
    } catch {
        throw ApplyIOError("failed to reload manifest: \(error)")
    }
    let selection: ProfileSelection = plan.profile.map { .explicit($0) } ?? .baseOnly
    let resolved: ResolvedManifest
    do {
        resolved = try resolveProfile(
            manifest, selection: selection, hostname: currentHostname(), os: currentOs()
        )
    } catch {
        throw ApplyIOError("failed to resolve manifest: \(error)")
    }
    for machineOverride in resolved.overrides
    where rustPathEqual(expandTargetPath(machineOverride.target, homeDir: plan.home), target) {
        throw ApplyIOError("refusing to replace machine override '\(target.string)'")
    }
    for excluded in resolved.exclusions.paths {
        if rustPathEqual(expandTargetPath(excluded, homeDir: plan.home), target)
            || rustComponents(bytes: Array(excluded.utf8)) == rustComponents(target)
        {
            throw ApplyIOError("refusing to replace excluded path '\(target.string)'")
        }
    }
    // Rust `to_string_lossy`.
    let targetText = String(decoding: pathBytes(target), as: UTF8.self)
    let fileName = rustFileName(target).flatMap { String(validating: $0, as: UTF8.self) }
    for pattern in resolved.exclusions.patterns {
        guard let glob = GlobPattern(pattern) else { continue }
        if glob.matches(targetText) || fileName.map({ glob.matches($0) }) == true {
            throw ApplyIOError("refusing to replace excluded path '\(target.string)'")
        }
    }
}

private func setLoginShell(_ ctx: ApplyContext, _ shell: FilePath) throws(ApplyIOError) -> Outcome {
    guard let shellText = String(validatingUTF8Path: shell) else {
        throw ApplyIOError("login shell path '\(shell.string)' is not valid UTF-8")
    }
    if try !shellListed(shellText), !ctx.allowSudo {
        throw ApplyIOError(sudoRequired)
    }
    if try !shellListed(shellText) {
        try appendShell(ctx, shellText)
    }
    // Only recorded so the journal can show what was replaced.
    let previous = (try? observeLoginShell(ctx.runner)) ?? ""
    try runProgram(ctx.runner, "chsh", ["-s", shellText])
    return Outcome(status: .done, previousShell: previous.isEmpty ? nil : previous)
}

private func shellListed(_ shell: String) throws(ApplyIOError) -> Bool {
    let bytes: [UInt8]
    do {
        bytes = try readAllBytes(FilePath("/etc/shells"))
    } catch {
        throw ApplyIOError("failed to read /etc/shells: \(error)")
    }
    guard let text = String(validating: bytes, as: UTF8.self) else {
        throw ApplyIOError("failed to read /etc/shells: stream did not contain valid UTF-8")
    }
    return planLines(text).contains { line in
        let trimmed = rustTrim(line)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#") && trimmed == shell
    }
}

private func appendShell(_ ctx: ApplyContext, _ shell: String) throws(ApplyIOError) {
    // Constant script. The shell path is a separate argument, never interpolated into it.
    let script = #"printf '%s\n' "$1" >> /etc/shells"#
    try runProgram(ctx.runner, "sudo", ["--", "/bin/sh", "-c", script, "sh", shell])
}

/// `r-` plus the first 16 hex characters of SHA-256(digest UTF-8 ‖ now as big-endian u64).
func makeRunId(digest: String, now: UInt64) -> String {
    var bytes = Array(digest.utf8)
    withUnsafeBytes(of: now.bigEndian) { bytes.append(contentsOf: $0) }
    return "r-" + sha256Hex(bytes).prefix(16)
}
