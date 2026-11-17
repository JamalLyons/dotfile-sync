// Port of crates/dotfilesync-cli/src/commands/{apply,jobs,runs}.rs. These always go through
// the agent (apply's non-TTY/dry-run preview is the one local exception, as in Rust).

import ArgumentParser
import Core
import IPC
import System

// MARK: - apply

struct ApplyCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a reviewed plan through dotfilesyncd (requires the agent)"
    )

    @Option(help: "Path to the manifest (default: ./dotfilesync.toml)")
    var manifest: String = "dotfilesync.toml"

    @Option(help: "Profile name. Omit to select from `[select]` (or the base layer).")
    var profile: String?

    @Flag(help: "Apply without prompting")
    var yes = false

    @Flag(help: "Allow the login-shell step to run `chsh` (never implied)")
    var allowSudo = false

    @Flag(help: "Print the plan and exit. Never applies.")
    var dryRun = false

    @Option(help: ArgumentHelp("Continue a run that stopped before every step finished", valueName: "RUN_ID"))
    var resume: String?

    @Option(help: "Override the home directory (primarily for testing)")
    var home: String?

    @Option(help: "Override the repository root (defaults to the manifest's parent)")
    var repoRoot: String?

    @Option(help: .hidden)
    var brewBin: String?

    var planArgs: PlanArgs {
        PlanArgs(manifest: manifest, profile: profile, home: home, repoRoot: repoRoot)
    }

    func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
        if let resume {
            return try executeResume(resume, ctx, dataDir: dataDir)
        }
        let previewOnly = dryRun || (!yes && !ctx.stdinIsTerminal)
        if previewOnly {
            let planned = try localPlan(planArgs, brewBin: brewOverride(brewBin, ctx), ctx)
            try printPlan(planned, json: false, ctx)
            if dryRun {
                ctx.err("Dry run: nothing was applied.")
            } else {
                ctx.err("note: not a TTY and --yes was not passed; dry-run only, nothing was applied.")
            }
            return
        }
        if brewBin != nil {
            throw CLIError("--brew-bin only applies to a local preview. Start dotfilesyncd with its own --brew-bin, then run apply without it.")
        }

        let conn = try connect(dataDir, ctx)
        let planned = try agentPlan(conn, planArgs.input(absolute: true, ctx), ctx)
        try printPlan(planned, json: false, ctx)
        if planned.isEmpty {
            ctx.err("Nothing to apply.")
            return
        }
        if !yes && !confirm("Apply \(planned.actions.count) actions? [y/N] ", ctx) {
            ctx.err("Not applied.")
            return
        }
        let grant = try approval(conn, planId: planned.planId, digest: planned.digest)
        let job = try conn.job(.planApply(planId: planned.planId, token: grant.token, allowSudo: allowSudo))
        ctx.err("dotfilesyncd (pid \(conn.info.pid)) is applying plan \(planned.planId) as job \(job.jobId).")
        try finishApply(conn, job, ctx)
    }

    private func executeResume(_ runId: String, _ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
        if !dryRun && !yes && !ctx.stdinIsTerminal {
            ctx.err("note: not a TTY and --yes was not passed; dry-run only, nothing was resumed.")
            return
        }
        let conn = try connect(dataDir, ctx)
        let view = try runView(conn, runId)
        ctx.out("Run \(view.runId) status \(view.status) (plan \(view.planId))")
        if let why = view.notResumable {
            throw CLIError("run \(view.runId) cannot be resumed: \(why.message) (\(why.reason))")
        }
        if dryRun {
            ctx.err("Dry run: nothing was resumed.")
            return
        }
        if !yes && ctx.stdinIsTerminal && !confirm("Resume run \(view.runId)? [y/N] ", ctx) {
            ctx.err("Not resumed.")
            return
        }
        let grant = try approval(conn, planId: view.planId, digest: view.planDigest)
        let job = try conn.job(.planResume(runId: view.runId, token: grant.token, allowSudo: allowSudo))
        ctx.err("dotfilesyncd (pid \(conn.info.pid)) is resuming run \(view.runId) as job \(job.jobId).")
        try finishApply(conn, job, ctx)
    }
}

/// Requests a one-time approval. The token is passed straight to the agent and never printed.
func approval(_ conn: AgentConnection, planId: String, digest: String) throws(CLIError) -> ApprovalGrant {
    let response = try conn.call(.planApprove(planId: planId, digest: digest))
    guard case let .approval(grant) = response else { throw unexpectedResponse(response) }
    return grant
}

func runView(_ conn: AgentConnection, _ runId: String) throws(CLIError) -> RunView {
    let response = try conn.call(.planRunStatus(runId: runId))
    guard case let .run(view) = response else { throw unexpectedResponse(response) }
    return view
}

func finishApply(_ conn: AgentConnection, _ job: JobSnapshot, _ ctx: CLIContext) throws(CLIError) {
    switch try follow(conn, job, quiet: false, ctx) {
    case let .finished(.apply(journal)):
        ctx.err("Run \(journal.runId) completed.")
    case let .failed(job):
        throw failure(job)
    case let .finished(other):
        throw unexpected(other)
    case .detached:
        return
    }
}

func confirm(_ prompt: String, _ ctx: CLIContext) -> Bool {
    ctx.stderr(prompt)
    let answer = rustTrim(ctx.readLine() ?? "").lowercased()
    return answer == "y" || answer == "yes"
}

// MARK: - runs

struct RunsCommand: ParsableCommand, CLIRunnable {
    static let configuration = CommandConfiguration(
        commandName: "runs",
        abstract: "List or show apply runs recorded by dotfilesyncd",
        subcommands: [List.self, Show.self]
    )

    @Flag(help: "With no subcommand, print JSON instead of a table")
    var json = false

    func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
        try listRuns(json: json, ctx, dataDir: dataDir)
    }

    struct List: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            abstract: "List runs, including interrupted runs from a previous agent process"
        )

        @Flag(help: "Print JSON instead of a table")
        var json = false

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            try listRuns(json: json, ctx, dataDir: dataDir)
        }
    }

    struct Show: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(abstract: "Show one run's journal")

        @Argument var runId: String

        @Flag(help: "Print JSON")
        var json = false

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let conn = try connect(dataDir, ctx)
            let view = try runView(conn, runId)
            if json {
                ctx.out(try renderJSON(view))
            } else {
                ctx.stdout(renderRunView(view))
            }
        }
    }
}

func listRuns(json: Bool, _ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
    let conn = try connect(dataDir, ctx)
    let response = try conn.call(.planRuns)
    guard case let .runs(runs) = response else { throw unexpectedResponse(response) }
    if json {
        ctx.out(try renderJSON(runs))
    } else if runs.isEmpty {
        ctx.out("No runs.")
    } else {
        for run in runs {
            ctx.out("\(run.runId)  \(padRight(run.status.description, 12))  plan \(run.planId)  job \(run.jobId)")
        }
    }
}

// MARK: - jobs

struct JobsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jobs",
        abstract: "Inspect, follow, or cancel jobs running in dotfilesyncd",
        subcommands: [List.self, Show.self, Watch.self, Result.self, Cancel.self]
    )

    func run() throws {
        throw MissingSubcommand(command: JobsCommand.self)
    }

    struct List: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            abstract: "List jobs known to the agent, including interrupted jobs from a previous run"
        )

        @Flag var json = false

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let conn = try connect(dataDir, ctx)
            let response = try conn.call(.listJobs)
            guard case let .jobs(jobs) = response else { throw unexpectedResponse(response) }
            if json {
                ctx.out(try renderJSON(jobs))
            } else if jobs.isEmpty {
                ctx.out("No jobs.")
            } else {
                for job in jobs { ctx.out(jobLine(job)) }
            }
        }
    }

    struct Show: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(abstract: "Show one job's status")

        @Argument var jobId: String
        @Flag var json = false

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let conn = try connect(dataDir, ctx)
            let job = try conn.job(.jobStatus(jobId: jobId))
            ctx.out(json ? try renderJSON(job) : jobLine(job))
        }
    }

    struct Watch: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            abstract: "Reconnect to a job: print progress after SEQ, then wait for it to finish",
            aliases: ["follow"]
        )

        @Argument var jobId: String

        @Option(help: "Only show events with a sequence number greater than this")
        var since: UInt64 = 0

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let conn = try connect(dataDir, ctx)
            let response = try conn.call(.jobProgress(jobId: jobId, sinceSeq: since))
            guard case let .progress(job, missed, truncated) = response else { throw unexpectedResponse(response) }
            if truncated {
                ctx.err("(older progress events were discarded by the daemon)")
            }
            var last = since
            for event in missed {
                ctx.out("  [\(event.stage)] \(event.message)")
                last = max(last, event.seq)
            }
            let final = job.status.isTerminal
                ? job
                : try conn.watch(jobId, since: last) { event in
                    ctx.out("  [\(event.stage)] \(event.message)")
                }
            ctx.out(jobLine(final))
        }
    }

    struct Result: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(abstract: "Print the report of a finished job")

        @Argument var jobId: String
        @Flag var json = false

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let conn = try connect(dataDir, ctx)
            let job = try conn.job(.jobStatus(jobId: jobId))
            switch try finish(conn, job) {
            case let .finished(.scan(report)): try printScan(report, json: json, ctx)
            case let .finished(.status(report)): try printStatus(report, json: json, ctx)
            case let .finished(.plan(plan, _)): try printPlan(plan, json: json, ctx)
            case let .finished(.apply(journal)):
                if json {
                    ctx.out(try renderJSON(journal))
                } else {
                    ctx.stdout(renderRun(journal))
                }
            case let .failed(job): throw failure(job)
            case .detached: throw CLIError("job \(jobId) has no result yet")
            }
        }
    }

    struct Cancel: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            abstract: "Request cancellation of a running job (also stops its subprocesses)"
        )

        @Argument var jobId: String

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let conn = try connect(dataDir, ctx)
            ctx.out(jobLine(try conn.job(.cancelJob(jobId: jobId))))
        }
    }
}

func jobLine(_ job: JobSnapshot) -> String {
    var s = "\(job.jobId)  \(padRight(job.kind.description, 6))  \(job.status)"
    if job.cancelRequested && !job.status.isTerminal {
        s += " (cancel requested)"
    }
    if job.fromPreviousRun {
        s += "  [previous daemon run]"
    }
    if let error = job.error {
        s += "  - \(error.message)"
    }
    return s
}
