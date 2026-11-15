// Port of crates/dotfilesync-core/src/plan/planner.rs (`run_plan` and helpers).

import Darwin
import Foundation
import System

private struct Draft {
    var kind: ActionKind
    var summary: String
    var risk: Risk
    var reversible: Bool
    var backup: Bool
}

/// Computes a deterministic plan that converges the machine to the manifest.
///
/// Read-only: inspects Homebrew, tracked configs and the login shell, but changes nothing.
/// Stages are reported through `progress`; `isCancelled` is checked between stages.
public func runPlan(
    _ input: PlanInput,
    runner: any CommandRunner,
    hostname: String,
    progress: (OpStage) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
) throws(OpError) -> Plan {
    try checkCancelled(isCancelled)
    progress(.loadingManifest)
    let resolved: ResolvedManifest
    do {
        let manifest = try loadManifest(input.manifest.string)
        resolved = try resolveProfile(
            manifest,
            selection: profileSelection(input.profile),
            hostname: hostname,
            os: currentOs()
        )
    } catch {
        throw .manifest(path: input.manifest, source: error)
    }

    try checkCancelled(isCancelled)
    progress(.discoveringHomebrew)
    let brew = discoverHomebrew(runner)

    try checkCancelled(isCancelled)
    progress(.inspectingConfigs)
    let repoRoot = defaultRepoRoot(manifest: input.manifest, repoRoot: input.repoRoot)
    let inspector = ConfigInspector(
        repoRoot: repoRoot,
        homeDir: input.home,
        exclusions: resolved.exclusions,
        overrides: resolved.overrides
    )
    let configs = inspector.inspectFiles(resolved.files)

    try checkCancelled(isCancelled)
    progress(.planning)

    let loginShell = observeLoginShell(runner)

    var drafts: [Draft] = []
    if brew.available && brew.packagesEnumerated {
        pushPackages(&drafts, resolved: resolved, brew: brew)
    }
    var fileActions: [Draft] = []
    var overrideActions: [Draft] = []
    for (file, observed) in zip(resolved.files, configs) {
        if let draft = planFile(file, observed: observed, resolved: resolved, home: input.home) {
            if case .ensureLocalOverride = draft.kind {
                overrideActions.append(draft)
            } else {
                fileActions.append(draft)
            }
        }
    }
    fileActions = sortedByTarget(fileActions)
    overrideActions = sortedByTarget(overrideActions)
    drafts.append(contentsOf: fileActions)

    // BTreeSet<PathBuf>: membership by component-wise path equality.
    var covered = Set<[RustPathComponent]>()
    for draft in overrideActions {
        covered.insert(rustComponents(actionTarget(draft.kind)))
    }
    for file in resolved.files {
        covered.insert(rustComponents(expandTargetPath(file.target, homeDir: input.home)))
    }
    for machineOverride in resolved.overrides {
        let target = expandTargetPath(machineOverride.target, homeDir: input.home)
        if covered.contains(rustComponents(target)) || planPathPresent(target) {
            continue
        }
        overrideActions.append(localOverrideAction(target: target, template: nil))
    }
    overrideActions = sortedByTarget(overrideActions)
    drafts.append(contentsOf: overrideActions)

    if resolved.setup.fisher
        && !planPathPresent(input.home.appending(".config/fish/functions/fisher.fish"))
    {
        drafts.append(Draft(
            kind: .installFisher, summary: "install fisher", risk: .medium, reversible: false, backup: false
        ))
        drafts.append(Draft(
            kind: .fisherUpdate, summary: "fisher update", risk: .medium, reversible: false, backup: false
        ))
    }

    if let shellName = resolved.setup.loginShell {
        let shell = try resolveShell(runner, brewPath: brew.brewPath, name: shellName)
        if loginShell != shell.string {
            drafts.append(Draft(
                kind: .setLoginShell(shell: shell),
                summary: "set login shell to \(shell.string)",
                risk: .high,
                reversible: true,
                backup: false
            ))
        }
    }

    let actions = drafts.enumerated().map { index, draft in
        PlanAction(
            id: formatActionId(index + 1),
            kind: draft.kind,
            summary: draft.summary,
            risk: draft.risk,
            reversible: draft.reversible,
            backup: draft.backup
        )
    }

    try checkCancelled(isCancelled)
    return Plan(
        schema: PLAN_SCHEMA,
        profile: resolved.profile,
        manifestPath: input.manifest,
        home: input.home,
        repoRoot: repoRoot,
        actions: actions,
        stateFingerprint: stateFingerprint(brew: brew, configs: configs, loginShell: loginShell)
    )
}

/// `format!("a-{:03}", n)`.
private func formatActionId(_ n: Int) -> String {
    let digits = String(n)
    return "a-" + String(repeating: "0", count: max(0, 3 - digits.count)) + digits
}

/// Stable sort by target path, Rust `Path::cmp` order.
private func sortedByTarget(_ drafts: [Draft]) -> [Draft] {
    stableSorted(drafts) { rustPathPrecedes(actionTarget($0.kind), actionTarget($1.kind)) }
}

private func pushPackages(_ drafts: inout [Draft], resolved: ResolvedManifest, brew: BrewDiscoveryResult) {
    let installedFormulae = Set(brew.formulae.map(\.name))
    let installedCasks = Set(brew.casks.map(\.name))
    for name in resolved.homebrew.formulae where !installedFormulae.contains(name) {
        drafts.append(packageAction(.brewInstallFormula(name: name), "brew install \(name)", .low))
    }
    for name in resolved.homebrew.casks where !installedCasks.contains(name) {
        drafts.append(packageAction(.brewInstallCask(name: name), "brew install --cask \(name)", .medium))
    }
}

private func packageAction(_ kind: ActionKind, _ summary: String, _ risk: Risk) -> Draft {
    Draft(kind: kind, summary: summary, risk: risk, reversible: false, backup: false)
}

private func planFile(
    _ file: TrackedFile,
    observed: ObservedConfigFile,
    resolved: ResolvedManifest,
    home: FilePath
) -> Draft? {
    if observed.state == .excluded {
        return nil
    }
    if isProtected(file, resolved: resolved, home: home) {
        if observed.state == .missing {
            let template = isRegularFileFollowing(observed.sourcePath) ? observed.sourcePath : nil
            return localOverrideAction(target: observed.targetPath, template: template)
        }
        return nil
    }
    switch observed.state {
    case .sourceMissing, .sourceOutsideRoot, .unreadable, .machineLocal:
        return nil
    default:
        break
    }

    let converged: Bool
    switch file.mode {
    case .copy: converged = observed.state == .matching
    case .symlink: converged = observed.state == .symlinkToSource
    }
    if converged {
        return nil
    }
    let exists = observed.state != .missing
    let verb = file.mode == .copy ? "copy" : "link"
    let summary = "\(verb) \(observed.sourcePath.string) -> \(observed.targetPath.string)"
    let kind: ActionKind
    switch file.mode {
    case .copy: kind = .copyFile(source: observed.sourcePath, target: observed.targetPath)
    case .symlink: kind = .linkFile(source: observed.sourcePath, target: observed.targetPath)
    }
    return Draft(kind: kind, summary: summary, risk: exists ? .medium : .low, reversible: true, backup: exists)
}

private func localOverrideAction(target: FilePath, template: FilePath?) -> Draft {
    Draft(
        kind: .ensureLocalOverride(target: target, template: template),
        summary: "ensure local override \(target.string)",
        risk: .low,
        reversible: true,
        backup: false
    )
}

private func isProtected(_ file: TrackedFile, resolved: ResolvedManifest, home: FilePath) -> Bool {
    if file.machineLocal || isLocalFish(file.source) || isLocalFish(file.target) {
        return true
    }
    let expanded = expandTargetPath(file.target, homeDir: home)
    return resolved.overrides.contains { machineOverride in
        machineOverride.target == file.target
            || rustPathEqual(expandTargetPath(machineOverride.target, homeDir: home), expanded)
    }
}

/// `Path::new(path).file_name() == Some("local.fish")` on the raw manifest string.
private func isLocalFish(_ path: String) -> Bool {
    rustComponents(bytes: Array(path.utf8)).last == .normal(Array("local.fish".utf8))
}

private func actionTarget(_ kind: ActionKind) -> FilePath {
    switch kind {
    case let .copyFile(_, target), let .linkFile(_, target), let .ensureLocalOverride(target, _):
        return target
    default:
        return FilePath("")
    }
}

/// Rust `fs::symlink_metadata(path).is_ok()`.
func planPathPresent(_ path: FilePath) -> Bool {
    if case .success = lstatPath(path) {
        return true
    }
    return false
}

/// Rust `Path::is_file`: `stat` (follows symlinks) reports a regular file.
func isRegularFileFollowing(_ path: FilePath) -> Bool {
    var st = stat()
    guard path.withPlatformString({ stat($0, &st) }) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFREG
}

/// The current login shell from `dscl . -read /Users/$USER UserShell`, or `""` on failure.
func observeLoginShell(_ runner: any CommandRunner) -> String {
    let user = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
    let record = "/Users/\(user)"
    guard let output = try? runner.run("dscl", args: [".", "-read", record, "UserShell"]) else {
        return ""
    }
    return rustSplitWhitespace(output.stdout).last ?? ""
}

/// Rust `str::split_whitespace` (Unicode `White_Space`, empty pieces dropped).
func rustSplitWhitespace(_ text: String) -> [String] {
    text.unicodeScalars
        .split(whereSeparator: { $0.properties.isWhitespace })
        .map { String(String.UnicodeScalarView($0)) }
}

private func resolveShell(
    _ runner: any CommandRunner,
    brewPath: FilePath?,
    name: String
) throws(OpError) -> FilePath {
    guard let brewPath else {
        throw .failed("Homebrew executable not found; cannot resolve login shell via brew prefix")
    }
    let output: CommandOutput
    switch runBrew(runner, brewPath: brewPath, args: ["--prefix"]) {
    case let .success(value): output = value
    case let .failure(message): throw .failed("failed to resolve Homebrew prefix: \(message)")
    }
    let prefix = rustTrim(planLines(output.stdout).first ?? "")
    if prefix.isEmpty {
        throw .failed("brew --prefix returned an empty path")
    }
    return FilePath(prefix).pushing(FilePath("bin")).pushing(FilePath(name))
}

private enum BrewResult {
    case success(CommandOutput)
    case failure(String)
}

private func runBrew(_ runner: any CommandRunner, brewPath: FilePath, args: [String]) -> BrewResult {
    guard let program = String(validatingUTF8Path: brewPath) else {
        return .failure("brew path '\(brewPath.string)' is not valid UTF-8")
    }
    do {
        return .success(try runner.run(program, args: args))
    } catch {
        return .failure(error.description)
    }
}

extension String {
    /// Rust `Path::to_str`: the path as a `String` when its bytes are valid UTF-8.
    init?(validatingUTF8Path path: FilePath) {
        guard let value = String(validating: pathBytes(path), as: UTF8.self) else { return nil }
        self = value
    }
}

/// Rust `str::lines`: split on `\n`, strip one trailing `\r`, no final empty line.
func planLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current: [UInt8] = []
    var sawAny = false
    for byte in text.utf8 {
        sawAny = true
        if byte == UInt8(ascii: "\n") {
            if current.last == UInt8(ascii: "\r") { current.removeLast() }
            lines.append(String(decoding: current, as: UTF8.self))
            current = []
        } else {
            current.append(byte)
        }
    }
    if sawAny && !current.isEmpty {
        if current.last == UInt8(ascii: "\r") { current.removeLast() }
        lines.append(String(decoding: current, as: UTF8.self))
    }
    return lines
}

/// Rust `str::cmp`: byte-wise order of UTF-8.
private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

private func stateFingerprint(
    brew: BrewDiscoveryResult,
    configs: [ObservedConfigFile],
    loginShell: String
) -> String {
    var lines: [String] = []
    for pkg in stableSorted(brew.formulae, by: { utf8Precedes($0.name, $1.name) }) {
        lines.append("formula\t\(pkg.name)\t\(pkg.version ?? "")")
    }
    for pkg in stableSorted(brew.casks, by: { utf8Precedes($0.name, $1.name) }) {
        lines.append("cask\t\(pkg.name)\t\(pkg.version ?? "")")
    }
    for cfg in stableSorted(configs, by: { rustPathPrecedes($0.targetPath, $1.targetPath) }) {
        lines.append("file\t\(cfg.targetPath.string)\t\(observedToken(cfg))")
    }
    lines.append("shell\t\(loginShell)")
    return sha256Hex(Array(lines.joined(separator: "\n").utf8))
}

private func observedToken(_ cfg: ObservedConfigFile) -> String {
    switch cfg.state {
    case .missing, .sourceMissing:
        return "missing"
    case .symlinkToSource, .symlinkExternal, .brokenSymlink:
        return "symlink:\(cfg.symlinkTarget?.string ?? "")"
    default:
        return "sha:\(cfg.targetHash ?? "")"
    }
}
