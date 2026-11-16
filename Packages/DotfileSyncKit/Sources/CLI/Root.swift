// Port of crates/dotfilesync-cli/src/main.rs: the command tree and the entry point.

import ArgumentParser
import Core
import System

/// A parsed command that the CLI can run.
protocol CLIRunnable {
    func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError)
}

/// The version printed by `--version` (same as the Rust crate).
public let CLI_VERSION = "0.1.0"

/// `dotfilesync`: macOS developer environment manager.
struct Root: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dotfilesync",
        abstract: "macOS developer environment manager",
        discussion: """
        dotfilesync inspects, tracks, and safely reports drift across Homebrew packages and explicit configuration files.

        plan shows what would change. apply changes the machine only through dotfilesyncd, after approval, with backups and locks.

        scan, status, and plan use the per-user agent (dotfilesyncd) when it is running and otherwise run in this process. apply requires the agent. Nothing listens on the network.
        """,
        version: CLI_VERSION,
        subcommands: [
            ScanCommand.self, StatusCommand.self, PlanCommand.self, ApplyCommand.self,
            RunsCommand.self, ImportBrewfileCommand.self, JobsCommand.self, ServiceCommand.self,
        ]
    )

    /// Documented here for `--help`; `runCLI` extracts it from any position (clap `global = true`).
    @Option(help: "dotfilesyncd data directory (default: $DOTFILESYNC_DATA_DIR or ~/Library/Application Support/dotfilesync). Accepted before or after the subcommand.")
    var dataDir: String?

    func run() throws {
        throw MissingSubcommand(command: Root.self)
    }
}

/// Removes every `--data-dir <DIR>` / `--data-dir=<DIR>` before `--` and returns the last one,
/// so the option works on any subcommand like clap's `global = true`.
func extractDataDir(_ args: [String]) -> (args: [String], dataDir: String?, missingValue: Bool) {
    var rest: [String] = []
    var dataDir: String?
    var index = 0
    var sawTerminator = false
    while index < args.count {
        let arg = args[index]
        if sawTerminator {
            rest.append(arg)
        } else if arg == "--" {
            sawTerminator = true
            rest.append(arg)
        } else if arg == "--data-dir" {
            guard index + 1 < args.count else { return (rest, dataDir, true) }
            dataDir = args[index + 1]
            index += 1
        } else if arg.hasPrefix("--data-dir=") {
            dataDir = String(arg.dropFirst("--data-dir=".count))
        } else {
            rest.append(arg)
        }
        index += 1
    }
    return (rest, dataDir, false)
}

/// Runs `dotfilesync` with `arguments` (without the program name) and returns the exit code.
///
/// Exit codes match the Rust CLI: 0 on success (and for `--help`/`--version`), 1 when a command
/// fails (`Error: …` on stderr), 2 for usage errors (usage message on stderr).
public func runCLI(_ arguments: [String], context ctx: CLIContext) -> Int32 {
    let (args, dataDir, missingValue) = extractDataDir(arguments)
    if missingValue {
        ctx.stderr("Error: Missing value for '--data-dir <data-dir>'\nUsage: \(Root.usageString())\n  See 'dotfilesync --help' for more information.\n")
        return 2
    }
    let command: any ParsableCommand
    do {
        command = try Root.parseAsRoot(args)
    } catch {
        return report(error, ctx)
    }
    guard let runnable = command as? any CLIRunnable else {
        // `help …` (ArgumentParser's built-in command) or a group invoked without a subcommand.
        var builtin = command
        do {
            try builtin.run()
            return 0
        } catch let missing as MissingSubcommand {
            // clap: a group without its subcommand is a usage error (exit 2, help on stderr).
            ctx.stderr(Root.helpMessage(for: missing.command) + "\n")
            return 2
        } catch {
            return report(error, ctx)
        }
    }
    do {
        try runnable.execute(ctx, dataDir: dataDir.map { FilePath($0) })
        return 0
    } catch {
        ctx.stderr(error.rendered)
        return 1
    }
}

/// Prints a parse-time error or help request: help/version on stdout (exit 0), usage errors on
/// stderr (exit 2), like clap.
private func report(_ error: any Error, _ ctx: CLIContext) -> Int32 {
    let message = Root.fullMessage(for: error)
    if Root.exitCode(for: error) == .success {
        ctx.stdout(message.isEmpty ? "" : message + "\n")
        return 0
    }
    ctx.stderr(message + "\n")
    return 2
}

/// Thrown by a command group run without a subcommand.
struct MissingSubcommand: Error {
    let command: any ParsableCommand.Type
}
