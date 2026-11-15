// dotfilesyncd: the per-user agent process. Port of crates/dotfilesync-daemon/src/bin/dotfilesyncd.rs.
//
// Differences from Rust:
// - Serves XPC on a launchd Mach service instead of a Unix socket; opens no network sockets.
// - No flock single-instance lock: launchd runs at most one instance per Mach service.
// - `--dev-stdio` (development/tests only) serves IPC JSON lines over stdin/stdout because the
//   Mach service only exists under launchd and an anonymous XPC endpoint cannot be handed to
//   another process without an existing XPC channel.

import Agent
import Core
import Darwin
import Dispatch
import Foundation
import IPC
import System
import XPCTransport

let USAGE = """
dotfilesyncd - per-user dotfilesync agent (XPC only; no network listener)

USAGE:
    dotfilesyncd [--data-dir <DIR>] [--brew-bin <PATH>] [--mach-service <NAME>]
                 [--insecure-any-signer] [--dev-stdio]

OPTIONS:
    --data-dir <DIR>        Data directory (default: $\(DATA_DIR_ENV) or
                            ~/Library/Application Support/dotfilesync)
    --brew-bin <PATH>       Homebrew executable to use (default: $DOTFILESYNC_BREW_BIN, PATH,
                            /opt/homebrew/bin/brew, /usr/local/bin/brew)
    --mach-service <NAME>   Mach service to serve (default: \(AGENT_MACH_SERVICE))
    --insecure-any-signer   DEVELOPMENT ONLY: accept XPC peers with any code signature
                            (needed for ad-hoc-signed local builds). The same-user check
                            still applies.
    --dev-stdio             DEVELOPMENT/TESTS ONLY: do not use launchd; serve one IPC JSON
                            request per stdin line and write one Outcome JSON line per
                            request to stdout. Also starts an anonymous XPC listener.
    -V, --version           Print version
    -h, --help              Print help

Normally launched on demand by launchd (SMAppService). Stop with SIGTERM/SIGINT or a
`shutdown` request.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("dotfilesyncd: \(message)\n".utf8))
    exit(code)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("dotfilesyncd: \(message)\n".utf8))
}

struct Options {
    var dataDir: FilePath?
    var brewBin: FilePath?
    var machService = AGENT_MACH_SERVICE
    var anySigner = false
    var devStdio = false
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let v = args.next() else { fail("\(flag) needs a value\n\n\(USAGE)", code: 2) }
        return v
    }
    while let arg = args.next() {
        switch arg {
        case "--data-dir": options.dataDir = FilePath(value(arg))
        case "--brew-bin": options.brewBin = FilePath(value(arg))
        case "--mach-service": options.machService = value(arg)
        #if DEBUG
        case "--insecure-any-signer": options.anySigner = true
        #endif
        case "--dev-stdio": options.devStdio = true
        case "-V", "--version":
            print("dotfilesyncd \(AGENT_VERSION)")
            exit(0)
        case "-h", "--help":
            print(USAGE)
            exit(0)
        default:
            fail("unexpected argument \"\(arg)\"\n\n\(USAGE)", code: 2)
        }
    }
    return options
}

/// Serves `{"op":…}` lines from stdin on a background thread (dev/test mode).
func serveStdio(_ service: AgentService) {
    let thread = Thread {
        let out = FileHandle.standardOutput
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            // The peer is whoever owns our stdin pipe, i.e. the user who launched us.
            let outcome = service.handle(json: Data(line.utf8), callerUid: geteuid())
            let data = (try? JSONEncoder().encode(outcome))
                ?? Data(#"{"err":{"code":"internal","message":"cannot encode outcome"}}"#.utf8)
            out.write(data + Data("\n".utf8))
        }
    }
    thread.start()
}

// MARK: - Main

/// Runs the agent. Nonisolated on purpose: top-level code is main-actor isolated, and the signal
/// handlers below run on their own dispatch queue.
nonisolated func runAgent() -> Never {
    let options = parseOptions()
    let layout: DataLayout
    do {
        layout = try DataLayout.resolve(explicit: options.dataDir)
    } catch {
        fail(error.description)
    }

    // A vanished pipe reader must surface as EPIPE, not kill the agent.
    signal(SIGPIPE, SIG_IGN)
    // Handle SIGTERM/SIGINT through dispatch instead of async-signal handlers.
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let service: AgentService
    do {
        service = try AgentService(config: AgentConfig(layout: layout, brewBin: options.brewBin))
    } catch {
        fail(error.description)
    }

    let signalQueue = DispatchQueue(label: "dotfilesyncd.signals")
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
        source.setEventHandler {
            service.requestShutdown()
        }
        source.resume()
        signalSources.append(source)
    }

    let transportLog: Logger
    do {
        // Separate file: AgentService owns dotfilesyncd.log and its rotation.
        transportLog = try Logger(path: layout.logsDir.appending("xpc.log"), maxBytes: 1024 * 1024, keep: 3)
    } catch {
        note("cannot open the transport log: \(error.description); transport logging disabled")
        transportLog = Logger.disabled()
    }

    let policy: PeerRequirementPolicy = options.anySigner ? .insecureAnySigner : .sameTeam()
    if options.anySigner {
        note("WARNING: --insecure-any-signer: accepting XPC peers with any code signature (development only)")
    }

    let server: AgentXPCServer
    if options.devStdio {
        server = AgentXPCServer(anonymousFor: service, policy: policy, log: transportLog)
        serveStdio(service)
        note("\(AGENT_VERSION) serving --dev-stdio (pid \(getpid()), data dir \(layout.root.string))")
    } else {
        do {
            server = try AgentXPCServer(service: service, machService: options.machService, policy: policy, log: transportLog)
        } catch {
            _ = service.shutdown()
            fail("\(error.description) (the agent must be launched by launchd; see --dev-stdio for tests)")
        }
        note("\(AGENT_VERSION) listening on Mach service \(options.machService) (pid \(getpid()))")
    }
    if service.recoveredInterrupted > 0 {
        note("\(service.recoveredInterrupted) job(s) from the previous run were interrupted and will not be replayed")
    }

    while !service.waitForShutdownRequest(timeout: .seconds(3600)) {}
    note("shutting down")
    server.cancel()
    let unfinished = service.shutdown()
    if unfinished > 0 {
        note("\(unfinished) job(s) did not stop within the grace period")
    }
    note("stopped")
    exit(0)
}

runAgent()
