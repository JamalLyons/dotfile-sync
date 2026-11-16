// Port of crates/dotfilesync-cli/src/commands/{scan,status,plan,import}.rs.

import ArgumentParser
import Core
import Foundation
import IPC
import System

/// The source chain of a ``ManifestError`` (anyhow `Caused by:` entries after the error itself).
func manifestSources(_ error: ManifestError) -> [String] {
    switch error {
    case let .io(_, reason): return [error.description, reason]
    case let .parse(message): return [error.description, message]
    default: return [error.description]
    }
}

/// An ``OpError`` as anyhow would print it (`OpError` → `ManifestError` → its source).
func opError(_ error: OpError) -> CLIError {
    if case let .manifest(_, source) = error {
        return CLIError(error.description, causes: manifestSources(source))
    }
    return CLIError(error.description)
}

func brewOverride(_ flag: String?, _ ctx: CLIContext) -> FilePath? {
    if let flag { return FilePath(flag) }
    // `std::env::var_os` treats an empty value as set.
    return ctx.environment["DOTFILESYNC_BREW_BIN"].map { FilePath($0) }
}

func homeDir(_ flag: String?, _ ctx: CLIContext) -> FilePath {
    if let flag { return FilePath(flag) }
    return FilePath(ctx.environment["HOME"] ?? ".")
}

func runner(_ brewBin: FilePath?) -> RealCommandRunner {
    var runner = RealCommandRunner()
    if let brewBin {
        runner = runner.withBrewBinary(brewBin)
    }
    return runner
}

let STANDALONE_ONLY_FLAG = "--brew-bin/DOTFILESYNC_BREW_BIN"

/// A relative path as given, resolved against the context's directory for the local process.
func local(_ path: FilePath, _ ctx: CLIContext) -> FilePath {
    absolute(path, ctx)
}

func isFile(_ path: FilePath) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path.string, isDirectory: &isDir) && !isDir.boolValue
}

// MARK: - scan

struct ScanCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Discover installed Homebrew packages and inspect explicitly tracked configurations"
    )

    @Option(name: .shortAndLong, help: "Path to manifest file for tracked configurations (optional)")
    var manifest: String?

    @Flag(help: "Output report in JSON format")
    var json = false

    @Option(help: "Override home directory path (primarily for testing)")
    var home: String?

    @Option(help: "Override repository root path (defaults to manifest parent dir or current directory)")
    var repoRoot: String?

    @Option(help: "Where to run: auto (agent if running, else in-process), daemon (alias: agent), or standalone")
    var mode: Mode = .auto

    @Flag(help: "With the agent: start the job, print its id, and return without waiting")
    var detach = false

    @Option(help: .hidden)
    var brewBin: String?

    func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
        let brew = brewOverride(brewBin, ctx)
        let home = homeDir(self.home, ctx)
        // The explicit manifest, or `./dotfilesync.toml` if it exists.
        let manifest: FilePath? = self.manifest.map { FilePath($0) } ?? {
            let path = FilePath("dotfilesync.toml")
            return isFile(local(path, ctx)) ? path : nil
        }()
        let report: ScanReport
        switch try route(mode, dataDir: dataDir, command: "scan", standaloneOnly: brew.map { _ in STANDALONE_ONLY_FLAG }, ctx) {
        case let .standalone(note):
            if let note { ctx.err(note) }
            let input = ScanInput(manifest: manifest, home: home, repoRoot: repoRoot.map { FilePath($0) })
            do {
                report = try runScan(input, runner: runner(brew))
            } catch {
                throw opError(error)
            }
        case let .agent(conn):
            let input = ScanInput(
                manifest: manifest.map { absolute($0, ctx) },
                home: absolute(home, ctx),
                repoRoot: repoRoot.map { absolute(FilePath($0), ctx) }
            )
            switch try runJob(conn, .scan(input), detach: detach, quiet: json, ctx) {
            case let .detached(job):
                ctx.out(job.jobId)
                return
            case let .finished(.scan(r)): report = r
            case let .finished(other): throw unexpected(other)
            case let .failed(job): throw failure(job)
            }
        }
        try printScan(report, json: json, ctx)
    }
}

func printScan(_ report: ScanReport, json: Bool, _ ctx: CLIContext) throws(CLIError) {
    ctx.out(json ? try renderJSON(report) : renderScanReport(report))
}

// MARK: - status

struct StatusCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Compare desired state from manifest with observed system state"
    )

    @Option(name: .shortAndLong, help: "Path to manifest file (required)")
    var manifest: String

    @Flag(help: "Output status in JSON format")
    var json = false

    @Option(help: "Override home directory path (primarily for testing)")
    var home: String?

    @Option(help: "Override repository root path (defaults to manifest parent dir or current directory)")
    var repoRoot: String?

    @Option(help: "Where to run: auto (agent if running, else in-process), daemon (alias: agent), or standalone")
    var mode: Mode = .auto

    @Flag(help: "With the agent: start the job, print its id, and return without waiting")
    var detach = false

    @Option(help: .hidden)
    var brewBin: String?

    func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
        let brew = brewOverride(brewBin, ctx)
        let home = homeDir(self.home, ctx)
        let manifestPath = FilePath(manifest)
        let report: StatusReport
        switch try route(mode, dataDir: dataDir, command: "status", standaloneOnly: brew.map { _ in STANDALONE_ONLY_FLAG }, ctx) {
        case let .standalone(note):
            if let note { ctx.err(note) }
            let input = StatusInput(manifest: manifestPath, home: home, repoRoot: repoRoot.map { FilePath($0) })
            do {
                report = try runStatus(input, runner: runner(brew))
            } catch {
                if case let .manifest(_, source) = error {
                    // Same error chain as before the agent existed.
                    throw CLIError("Failed to read manifest from '\(manifest)'", causes: manifestSources(source))
                }
                throw opError(error)
            }
        case let .agent(conn):
            let input = StatusInput(
                manifest: absolute(manifestPath, ctx),
                home: absolute(home, ctx),
                repoRoot: repoRoot.map { absolute(FilePath($0), ctx) }
            )
            switch try runJob(conn, .status(input), detach: detach, quiet: json, ctx) {
            case let .detached(job):
                ctx.out(job.jobId)
                return
            case let .finished(.status(r)): report = r
            case let .finished(other): throw unexpected(other)
            case let .failed(job):
                if let error = job.error, error.code == .manifestLoad {
                    throw CLIError("Failed to read manifest from '\(manifest)': \(error.message)")
                }
                throw failure(job)
            }
        }
        try printStatus(report, json: json, ctx)
    }
}

func printStatus(_ report: StatusReport, json: Bool, _ ctx: CLIContext) throws(CLIError) {
    ctx.out(json ? try renderJSON(report) : renderStatusReport(report))
}

// MARK: - plan

struct PlanCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Show the changes that would bring this machine in line with the manifest"
    )

    @Option(help: "Path to the manifest (default: ./dotfilesync.toml)")
    var manifest: String = "dotfilesync.toml"

    @Option(help: "Profile name. Omit to select from `[select]` (or the base layer).")
    var profile: String?

    @Flag(help: "Print the plan as JSON")
    var json = false

    @Option(help: "Override the home directory (primarily for testing)")
    var home: String?

    @Option(help: "Override the repository root (defaults to the manifest's parent)")
    var repoRoot: String?

    @Option(help: "Where to plan: auto (agent if running, else in-process), daemon (alias: agent), or standalone")
    var mode: Mode = .auto

    @Option(help: .hidden)
    var brewBin: String?

    func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
        let brew = brewOverride(brewBin, ctx)
        let args = PlanArgs(manifest: manifest, profile: profile, home: home, repoRoot: repoRoot)
        let plan: Plan
        switch try route(mode, dataDir: dataDir, command: "plan", standaloneOnly: brew.map { _ in STANDALONE_ONLY_FLAG }, ctx) {
        case let .standalone(note):
            if let note { ctx.err(note) }
            plan = try localPlan(args, brewBin: brew, ctx)
        case let .agent(conn):
            plan = try agentPlan(conn, args.input(absolute: true, ctx), ctx)
        }
        try printPlan(plan, json: json, ctx)
    }
}

/// The plan inputs shared by `plan` and `apply`.
struct PlanArgs {
    var manifest: String
    var profile: String?
    var home: String?
    var repoRoot: String?

    func input(absolute makeAbsolute: Bool, _ ctx: CLIContext) -> PlanInput {
        let home = homeDir(self.home, ctx)
        let fix: (FilePath) -> FilePath = { makeAbsolute ? absolute($0, ctx) : $0 }
        return PlanInput(
            manifest: fix(FilePath(manifest)),
            home: fix(home),
            repoRoot: repoRoot.map { fix(FilePath($0)) },
            profile: profile
        )
    }
}

func printPlan(_ plan: Plan, json: Bool, _ ctx: CLIContext) throws(CLIError) {
    if json {
        ctx.out(try renderJSON(plan))
    } else {
        ctx.stdout(renderPlan(plan))
    }
}

func localPlan(_ args: PlanArgs, brewBin: FilePath?, _ ctx: CLIContext) throws(CLIError) -> Plan {
    do {
        return try runPlan(args.input(absolute: false, ctx), runner: runner(brewBin), hostname: currentHostname())
    } catch {
        throw opError(error)
    }
}

func agentPlan(_ conn: AgentConnection, _ input: PlanInput, _ ctx: CLIContext) throws(CLIError) -> Plan {
    let job = try conn.job(.planCreate(input: input))
    ctx.err("dotfilesyncd (pid \(conn.info.pid)) is planning as job \(job.jobId).")
    let finished = try conn.watch(job.jobId, since: 0) { event in
        ctx.err("  [\(event.stage)] \(event.message)")
    }
    switch try finish(conn, finished) {
    case let .finished(.plan(plan, _)): return plan
    case let .failed(job): throw failure(job)
    case let .finished(other): throw unexpected(other)
    case .detached: throw CLIError("plan watch returned a non-terminal snapshot")
    }
}

// MARK: - import-brewfile

struct ImportBrewfileCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "import-brewfile",
        abstract: "Statically parse and import package declarations from a Brewfile"
    )

    @Option(name: .shortAndLong, help: "Path to Brewfile to statically import")
    var brewfile: String

    @Option(name: .shortAndLong, help: "Optional destination path to write a new dotfilesync.toml manifest skeleton (refuses to overwrite existing files)")
    var output: String?

    @Flag(help: "Output parse results in JSON format")
    var json = false

    /// Always local: writes only with `--output`, with `O_EXCL` (never overwrites).
    func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
        let content: String
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: local(FilePath(brewfile), ctx).string))
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIError("Failed to read Brewfile at '\(brewfile)'", causes: ["stream did not contain valid UTF-8"])
            }
            content = text
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError("Failed to read Brewfile at '\(brewfile)'", causes: [ioReason(error)])
        }

        let result = parseBrewfile(content)

        if let output {
            var manifest = Manifest(schemaVersion: CURRENT_SCHEMA_VERSION)
            manifest.metadata = ManifestMetadata(
                name: "imported-brewfile",
                description: "Imported statically from '\(brewfile)'"
            )
            manifest.packageManagers = PackageManagersSection(
                homebrew: HomebrewSection(formulae: result.formulae, casks: result.casks)
            )
            let toml: String
            do {
                toml = try serializeManifest(manifest)
            } catch {
                throw CLIError(error.description)
            }
            try createNew(local(FilePath(output), ctx), display: output, contents: toml)
        }

        if json {
            ctx.out(try renderJSON(result))
        } else {
            ctx.out(renderImportResult(result, outputPath: output))
        }
    }
}

/// Rust `io::Error` display for a Foundation read error.
func ioReason(_ error: any Error) -> String {
    let ns = error as NSError
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return "\(String(cString: strerror(Int32(underlying.code)))) (os error \(underlying.code))"
    }
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
        return "No such file or directory (os error 2)"
    }
    return ns.localizedDescription
}

/// `OpenOptions::new().write(true).create_new(true)`: refuses to replace an existing file,
/// leaving its bytes untouched.
func createNew(_ path: FilePath, display: String, contents: String) throws(CLIError) {
    let fd = path.withPlatformString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644) }
    if fd < 0 {
        let code = errno
        if code == EEXIST {
            throw CLIError("Output manifest file '\(display)' already exists; refusing to overwrite to preserve existing configuration and exclusions.")
        }
        throw CLIError("Failed to create new output file '\(display)': \(String(cString: strerror(code))) (os error \(code))")
    }
    defer { close(fd) }
    let bytes = Array(contents.utf8)
    var written = 0
    while written < bytes.count {
        let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            let code = errno
            throw CLIError(
                "Failed to write manifest contents to '\(display)'",
                causes: ["\(String(cString: strerror(code))) (os error \(code))"]
            )
        }
        written += n
    }
}
