// Replaces crates/dotfilesync-cli/src/commands/service.rs (launchctl + a plist written to
// ~/Library/LaunchAgents) with SMAppService registration through `AgentRegistering`.
//
// Mapping from the Rust subcommands:
// - `install`   -> register the agent bundled in the app with launchd. launchd then starts it
//                  on demand when a client looks up its Mach service; there is no separate
//                  "start at login" switch or user-editable plist (`--start-at-login`,
//                  `--daemon-path` and `--force` are gone).
// - `uninstall` -> unregister. Keeps the data directory, configs and repositories.
// - `start`     -> connects to the Mach service, which makes launchd start the agent, and
//                  reports its pid. Needs a registered agent.
// - `stop`      -> asks a running agent to shut down (`shutdown` request). While registered,
//                  launchd starts it again on the next request; `uninstall` removes it.
// - `status`    -> registration state plus whether the agent answers; `--json` for scripts.
// - `open-settings` (new) -> opens System Settings → Login Items to approve the agent.

import AgentRegistration
import ArgumentParser
import Core
import IPC
import System
import XPCTransport

struct ServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Register or unregister the per-user dotfilesyncd agent with launchd (SMAppService); launchd starts it on demand",
        subcommands: [Install.self, Start.self, Stop.self, Status.self, Uninstall.self, OpenSettings.self]
    )

    func run() throws {
        throw MissingSubcommand(command: ServiceCommand.self)
    }

    struct Install: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            abstract: "Register the agent with launchd (SMAppService). launchd starts it on demand; nothing is started now."
        )

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let registration = ctx.registration()
            let outcome: RegisterOutcome
            do {
                outcome = try registration.register()
            } catch {
                throw CLIError(error.message)
            }
            switch outcome {
            case .registered: ctx.out("Registered: \(AGENT_PLIST_NAME)")
            case .alreadyRegistered: ctx.out("Already registered (unchanged): \(AGENT_PLIST_NAME)")
            }
            printApprovalHint(registration.status, ctx)
            ctx.out("The agent was not started. launchd starts it when dotfilesync first needs it (or run `dotfilesync service start`).")
        }
    }

    struct Start: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            abstract: "Ask launchd to start the registered agent now and check that it answers"
        )

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let layout = try resolveLayout(dataDir, ctx)
            if case let .up(info) = reach(layout, ctx) {
                ctx.out("dotfilesyncd is already running (pid \(info.pid)).")
                return
            }
            let status = ctx.registration().status
            guard status == .enabled else {
                throw CLIError("the agent is \(describe(status)); \(statusHint(status))")
            }
            // The Mach service lookup is what makes launchd launch the agent; this needs the data
            // directory, which the agent creates on its first run.
            switch reach(layout, ctx) {
            case let .up(info):
                ctx.out("dotfilesyncd \(info.daemonVersion) is running (pid \(info.pid)).")
            case let .down(why), let .error(why):
                throw CLIError("launchd has the agent registered but it is not answering (\(why)); check \(layout.logFile.string)")
            }
        }
    }

    struct Stop: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            abstract: "Ask a running agent to shut down (launchd starts it again on demand while it is registered)"
        )

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let layout = try resolveLayout(dataDir, ctx)
            let conn: AgentConnection
            do {
                conn = try tryConnect(layout, ctx)
            } catch {
                if error.isNotRunning {
                    ctx.out("dotfilesyncd is not running.")
                    return
                }
                throw explain(error, layout: layout)
            }
            _ = try conn.call(.shutdown)
            ctx.out("Asked dotfilesyncd (pid \(conn.info.pid)) to shut down; running jobs are cancelled.")
            if ctx.registration().status == .enabled {
                ctx.out("It stays registered, so launchd starts it again on the next request. Run `dotfilesync service uninstall` to remove it.")
            }
        }
    }

    struct Status: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            abstract: "Show whether the agent is registered with launchd and whether it answers"
        )

        @Flag(help: "Print the status as JSON")
        var json = false

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let layout = try resolveLayout(dataDir, ctx)
            let status = ctx.registration().status
            let reach = reach(layout, ctx)
            if json {
                ctx.out(try renderJSON(ServiceStatusReport(status, reach, layout)))
                return
            }
            ctx.out("Agent registration (SMAppService \(AGENT_PLIST_NAME)): \(describe(status))")
            if status != .enabled {
                ctx.out("  \(statusHint(status))")
            }
            switch reach {
            case let .up(info):
                ctx.out("Agent: running (dotfilesyncd \(info.daemonVersion), pid \(info.pid), data \(info.dataDir.string))")
            case let .down(why):
                ctx.out("Agent: not running (\(why))")
                ctx.out("  scan/status/plan will run standalone in the CLI process until it is started.")
            case let .error(why):
                ctx.out("Agent: unreachable: \(why)")
            }
        }
    }

    struct Uninstall: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            abstract: "Unregister the agent from launchd. Keeps your data, configs and repositories."
        )

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            let layout = try resolveLayout(dataDir, ctx)
            let outcome: UnregisterOutcome
            do {
                outcome = try ctx.registration().unregister()
            } catch {
                throw CLIError(error.message)
            }
            switch outcome {
            case .unregistered: ctx.out("Unregistered \(AGENT_PLIST_NAME); launchd stopped the agent.")
            case .notRegistered: ctx.out("The agent was not registered.")
            }
            ctx.out("Kept agent state and logs in \(layout.root.string) (remove manually if you no longer need them).")
            ctx.out("Your configuration files and any sync repositories were not touched.")
        }
    }

    struct OpenSettings: ParsableCommand, CLIRunnable {
        static let configuration = CommandConfiguration(
            commandName: "open-settings",
            abstract: "Open System Settings → General → Login Items to allow the agent"
        )

        func execute(_ ctx: CLIContext, dataDir: FilePath?) throws(CLIError) {
            ctx.registration().openSystemSettingsLoginItems()
            ctx.out("Opened System Settings → General → Login Items.")
        }
    }
}

enum Reach {
    case up(DaemonInfo)
    case down(String)
    case error(String)
}

/// Whether the agent answers `daemon_info`, without creating anything.
func reach(_ layout: DataLayout, _ ctx: CLIContext) -> Reach {
    do {
        return .up(try tryConnect(layout, ctx).info)
    } catch {
        if case let .notRunning(reason) = error {
            return .down(reason)
        }
        return .error(explain(error, layout: layout).message)
    }
}

func describe(_ status: AgentRegistrationStatus) -> String {
    switch status {
    case .notRegistered: return "not registered"
    case .enabled: return "registered and enabled"
    case .requiresApproval: return "registered, waiting for approval"
    case .notFound: return "not found in the app bundle"
    }
}

func statusHint(_ status: AgentRegistrationStatus) -> String {
    switch status {
    case .notRegistered: return "run `dotfilesync service install`"
    case .requiresApproval: return "allow it in System Settings → General → Login Items (`dotfilesync service open-settings`)"
    case .notFound: return "run dotfilesync from the installed app so its launchd definition can be found"
    case .enabled: return "launchd starts it on demand"
    }
}

func printApprovalHint(_ status: AgentRegistrationStatus, _ ctx: CLIContext) {
    if status == .requiresApproval {
        ctx.out("Approval needed: \(statusHint(status)).")
    }
}

/// `service status --json`.
struct ServiceStatusReport: Encodable {
    var registration: AgentRegistrationStatus
    var plistName: String
    var dataDir: String
    var agentRunning: Bool
    var agentPid: UInt32?
    var agentVersion: String?
    var agentError: String?

    init(_ status: AgentRegistrationStatus, _ reach: Reach, _ layout: DataLayout) {
        registration = status
        plistName = AGENT_PLIST_NAME
        dataDir = layout.root.string
        switch reach {
        case let .up(info):
            agentRunning = true
            agentPid = info.pid
            agentVersion = info.daemonVersion
        case let .down(why), let .error(why):
            agentRunning = false
            agentError = why
        }
    }

    private enum CodingKeys: String, CodingKey {
        case registration
        case plistName = "plist_name"
        case dataDir = "data_dir"
        case agentRunning = "agent_running"
        case agentPid = "agent_pid"
        case agentVersion = "agent_version"
        case agentError = "agent_error"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(registration, forKey: .registration)
        try c.encode(plistName, forKey: .plistName)
        try c.encode(dataDir, forKey: .dataDir)
        try c.encode(agentRunning, forKey: .agentRunning)
        try c.encodeIfPresent(agentPid, forKey: .agentPid)
        try c.encodeIfPresent(agentVersion, forKey: .agentVersion)
        try c.encodeIfPresent(agentError, forKey: .agentError)
    }
}
