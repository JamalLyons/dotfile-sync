// Executors for `promote_file` and `demote_file`.
//
// Both are idempotent so ``resumeRun(runDir:plan:context:progress:isCancelled:)`` can re-run a
// step that crashed mid-way: promote skips the copy when the repository source already holds
// the target's bytes and skips the manifest edit when the entry is already present; demote is
// `skipped` when the entry is already gone. The manifest is backed up by copy (never moved, so
// it always exists on disk) before it is rewritten atomically.

import Darwin
import System

struct ManifestChangeOutcome {
    var status: StepStatus
    var backupPath: FilePath?
}

/// Copies the machine target into the repository and appends the `[[files]]` entry.
func applyPromote(
    target: FilePath,
    source: FilePath,
    manifest: FilePath,
    entrySource: String,
    entryTarget: String,
    targetSha256: String,
    plan: Plan,
    ctx: ApplyContext,
    runId: String,
    actionId: String
) throws(ApplyIOError) -> ManifestChangeOutcome {
    let manifestContent = try readManifestText(manifest)
    let parsed: Manifest
    do {
        parsed = try parseManifest(manifestContent)
    } catch {
        throw ApplyIOError("failed to reload manifest: \(error)")
    }
    let existing = parsed.files.first {
        rustPathEqual(expandTargetPath($0.target, homeDir: plan.home), target)
    }
    if let existing, existing.source != entrySource {
        throw ApplyIOError(
            "'\(target.string)' is now managed with source '\(existing.source)'; re-plan the promotion"
        )
    }

    // A stored plan is data: re-derive the repository path from the entry and re-check it, so
    // neither a crafted `source` nor a symlinked repository directory can redirect the copy.
    let entrySourcePath = decodeManifestPathBytes(entrySource)
    guard rustPathEqual(source, plan.repoRoot.pushing(entrySourcePath)) else {
        throw ApplyIOError("repository path '\(source.string)' does not match entry source '\(entrySource)'")
    }
    try checkRepoSource(source, repoRoot: plan.repoRoot)

    // Preflight the manifest edit before anything is written.
    let edited: String?
    if existing == nil {
        do {
            edited = try appendingTrackedFile(
                TrackedFile(source: entrySource, target: entryTarget), to: manifestContent
            )
        } catch {
            throw ApplyIOError("cannot add '\(entryTarget)' to the manifest: \(error)")
        }
    } else {
        edited = nil
    }

    // Classified before it is read; fails closed when the target changed after planning.
    try checkPromotable(home: plan.home, target: target)
    let bytes = try readPromoteTarget(target)
    if sha256Hex(bytes) != targetSha256 {
        throw ApplyIOError("'\(target.string)' changed after the plan was approved; re-plan the promotion")
    }

    var sourceBackup: FilePath?
    let sourceMatches: Bool
    switch lstatPath(source) {
    case let .success(st):
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw ApplyIOError("repository path '\(source.string)' exists and is not a regular file")
        }
        let current: [UInt8]
        do {
            current = try readAllBytes(source)
        } catch {
            throw ApplyIOError("failed to read '\(source.string)': \(error)")
        }
        sourceMatches = current == bytes
        if !sourceMatches {
            sourceBackup = try backupByCopy(
                source, bytes: current, plan: plan, ctx: ctx, runId: runId, actionId: actionId
            )
        }
    case .failure:
        sourceMatches = false
    }
    if !sourceMatches {
        try writeAtomic(source, bytes: bytes, mode: fileMode(target) ?? 0o644)
    }

    guard let edited else {
        return ManifestChangeOutcome(status: .done, backupPath: sourceBackup)
    }
    let manifestBackup = try rewriteManifest(
        manifest, old: manifestContent, new: edited, plan: plan, ctx: ctx, runId: runId, actionId: actionId
    )
    return ManifestChangeOutcome(status: .done, backupPath: manifestBackup)
}

/// Removes the base `[[files]]` entry for `target`. Never touches the machine file.
func applyDemote(
    target: FilePath,
    manifest: FilePath,
    entryTarget: String,
    plan: Plan,
    ctx: ApplyContext,
    runId: String,
    actionId: String
) throws(ApplyIOError) -> ManifestChangeOutcome {
    let manifestContent = try readManifestText(manifest)
    let parsed: Manifest
    do {
        parsed = try parseManifest(manifestContent)
    } catch {
        throw ApplyIOError("failed to reload manifest: \(error)")
    }
    guard let index = parsed.files.firstIndex(where: {
        rustPathEqual(expandTargetPath($0.target, homeDir: plan.home), target)
    }) else {
        return ManifestChangeOutcome(status: .skipped)
    }
    let edited: String
    do {
        edited = try removingTrackedFile(at: index, from: manifestContent)
    } catch {
        throw ApplyIOError("cannot remove '\(entryTarget)' from the manifest: \(error)")
    }
    let backup = try rewriteManifest(
        manifest, old: manifestContent, new: edited, plan: plan, ctx: ctx, runId: runId, actionId: actionId
    )
    return ManifestChangeOutcome(status: .done, backupPath: backup)
}

private func readManifestText(_ manifest: FilePath) throws(ApplyIOError) -> String {
    guard case let .success(st) = lstatPath(manifest), (st.st_mode & S_IFMT) == S_IFREG else {
        throw ApplyIOError("manifest '\(manifest.string)' is missing or not a regular file")
    }
    let bytes: [UInt8]
    do {
        bytes = try readAllBytes(manifest)
    } catch {
        throw ApplyIOError("failed to read manifest '\(manifest.string)': \(error)")
    }
    guard let text = String(validating: bytes, as: UTF8.self) else {
        throw ApplyIOError("manifest '\(manifest.string)' is not valid UTF-8")
    }
    return text
}

private func rewriteManifest(
    _ manifest: FilePath,
    old: String,
    new: String,
    plan: Plan,
    ctx: ApplyContext,
    runId: String,
    actionId: String
) throws(ApplyIOError) -> FilePath {
    let mode = fileMode(manifest) ?? 0o644
    let backup = try backupByCopy(
        manifest, bytes: Array(old.utf8), plan: plan, ctx: ctx, runId: runId, actionId: actionId
    )
    try writeAtomic(manifest, bytes: Array(new.utf8), mode: mode)
    return backup
}

/// Writes `bytes` (the current content of `path`) to
/// `<backupRoot>/<runId>/<relative path>.backup.<stamp>.<actionId>`, keeping `path` in place.
/// The action id keeps backups from several steps of one run (same second) apart.
private func backupByCopy(
    _ path: FilePath,
    bytes: [UInt8],
    plan: Plan,
    ctx: ApplyContext,
    runId: String,
    actionId: String
) throws(ApplyIOError) -> FilePath {
    let relative = relativeToHome(home: plan.home, target: path)
    let fileName = rustFileName(relative).map { String(decoding: $0, as: UTF8.self) } ?? "file"
    let stamped = "\(fileName).backup.\(formatStamp(ctx.now())).\(actionId)"
    let parent = rustParent(relative) ?? FilePath("")
    let dest = ctx.backupRoot.pushing(FilePath(runId)).pushing(parent).pushing(FilePath(stamped))
    try writeAtomic(dest, bytes: bytes, mode: fileMode(path) ?? 0o644)
    return dest
}
