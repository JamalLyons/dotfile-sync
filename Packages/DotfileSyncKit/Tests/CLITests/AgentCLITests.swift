// Port of crates/dotfilesync-cli/tests/daemon_cli_tests.rs.
//
// "Not running" scenarios spawn the built binary with a temp, non-existent data dir: the
// client refuses before any Mach lookup, so the real agent is never contacted. Scenarios that
// need a running agent run `AgentService` behind an anonymous XPC listener and run the CLI
// in-process against its endpoint. `service` uses a fake `AgentServiceBackend`.

import Foundation
import IPC
import System
import Testing

private func manifest() -> String {
    fixture("sample_manifest.toml")
}

@Suite(.serialized) struct AgentCLITests {
    @Test func autoModeWithoutAgentFallsBackAndSaysSo() throws {
        let env = try Env()
        let auto = try env.cli(["scan", "--json"]).success()
        #expect(auto.stderr.contains("dotfilesyncd is not running"))
        #expect(auto.stderr.contains("standalone"))
        // Rust pointed at `dotfilesync service start`; registration replaced start/install.
        #expect(auto.stderr.contains("dotfilesync service install"))
        let report = try auto.json()
        let formulae = (report["homebrew"] as? [String: Any])?["formulae"] as? [[String: Any]]
        #expect(formulae?.first?["name"] as? String == "git")

        // Explicit standalone: same report, no note.
        let explicit = try env.cli(["scan", "--json", "--mode", "standalone"]).success()
        #expect(explicit.stderr.isEmpty)
        #expect(auto.stdout == explicit.stdout)
        // Checking for an agent never creates the data directory or installs anything.
        #expect(!exists(env.data))
        #expect(!exists(env.home.appending("Library")))
    }

    @Test func daemonModeWithoutAgentExplainsInsteadOfFallingBack() throws {
        let env = try Env()
        let status = try env.cli(["status", "--manifest", manifest(), "--mode", "daemon"]).failure()
        #expect(status.stderr.contains("dotfilesyncd is not running"))
        #expect(status.stderr.contains("dotfilesync service install"))
        // `--mode agent` is accepted as a synonym.
        let agent = try env.cli(["status", "--manifest", manifest(), "--mode", "agent"]).failure()
        #expect(agent.stderr.contains("dotfilesyncd is not running"))
        let jobs = try env.cli(["jobs", "list"]).failure()
        #expect(jobs.stderr.contains("not running"))
    }

    @Test func brewOverrideIsStandaloneOnly() throws {
        let env = try Env()
        let refused = try env.cli(["scan", "--mode", "daemon", "--brew-bin", env.brew.string]).failure()
        #expect(refused.stderr.contains("only applies to standalone mode"))
        // Even with an agent running, auto mode honours the override by running standalone.
        let agent = try TestAgent(env)
        let run = runInProcess(["scan", "--json", "--brew-bin", env.brew.string], env: env, endpoint: try agent.endpoint)
            .success()
        #expect(run.stderr.contains("running scan standalone"))
        #expect(!run.stderr.contains("as job j-"))
    }

    @Test func scanAndStatusThroughAgentMatchStandaloneOutput() throws {
        let env = try Env()
        let m = manifest()
        let standaloneScan = try env.cli(["scan", "--json", "--mode", "standalone", "--home", env.home.string]).success()
        let standaloneStatus = try env.cli([
            "status", "--json", "--mode", "standalone", "--manifest", m, "--home", env.home.string,
        ]).success()

        let agent = try TestAgent(env)
        let endpoint = try agent.endpoint
        let agentScan = runInProcess(["scan", "--json", "--home", env.home.string], env: env, endpoint: endpoint).success()
        #expect(agentScan.stderr.contains("as job j-"))
        #expect(agentScan.stdout == standaloneScan.stdout)

        let agentStatus = runInProcess(
            ["status", "--json", "--mode", "daemon", "--manifest", m, "--home", env.home.string],
            env: env, endpoint: endpoint
        ).success()
        #expect(agentStatus.stdout == standaloneStatus.stdout)

        // Human output streams progress on stderr and the report on stdout.
        let human = runInProcess(["scan", "--mode", "daemon"], env: env, endpoint: endpoint).success()
        #expect(human.stderr.contains("[discovering_homebrew]"))
        #expect(human.stderr.contains("Ctrl-C detaches"))
        #expect(human.stdout.contains("=== dotfilesync scan ==="))
    }

    @Test func statusManifestErrorIsTheSameInBothModes() throws {
        let env = try Env()
        let standalone = try env.cli(["status", "--manifest", "missing.toml", "--mode", "standalone"]).failure()
        #expect(standalone.stderr.contains("Failed to read manifest from 'missing.toml'"))
        let agent = try TestAgent(env)
        let viaAgent = runInProcess(
            ["status", "--manifest", "missing.toml", "--mode", "daemon"], env: env, endpoint: try agent.endpoint
        ).failure()
        #expect(viaAgent.stderr.contains("Failed to read manifest from 'missing.toml'"))
    }

    @Test func detachedJobCanBeReconnectedFromAnotherInvocation() throws {
        let env = try Env()
        let agent = try TestAgent(env)
        let endpoint = try agent.endpoint
        let id = runInProcess(["scan", "--detach"], env: env, endpoint: endpoint).success()
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(id.hasPrefix("j-"), "\(id)")

        let watch = runInProcess(["jobs", "watch", id], env: env, endpoint: endpoint).success()
        #expect(watch.stdout.contains("succeeded"))
        // `follow` is an alias of `watch`.
        runInProcess(["jobs", "follow", id], env: env, endpoint: endpoint).success()

        let result = try runInProcess(["jobs", "result", id, "--json"], env: env, endpoint: endpoint).success().json()
        let formulae = (result["homebrew"] as? [String: Any])?["formulae"] as? [[String: Any]]
        #expect(formulae?.first?["name"] as? String == "git")

        let list = runInProcess(["jobs", "list"], env: env, endpoint: endpoint).success()
        #expect(list.stdout.contains(id))
        let missing = runInProcess(["jobs", "show", "j-doesnotexist"], env: env, endpoint: endpoint).failure()
        #expect(missing.stderr.contains("no job with id"))
    }

    @Test func importBrewfileStaysLocalAndRefusesOverwrite() throws {
        let env = try Env()
        let out = env.tmp.appending("new.toml")
        let args = ["import-brewfile", "--brewfile", fixture("Brewfile.standard"), "--output", out.string]
        try env.cli(args).success()
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out.string))
        let second = try env.cli(args).failure()
        #expect(second.stderr.contains("refusing to overwrite"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: out.string)) == bytes)
        #expect(!exists(env.data), "import never involves the agent")
    }

    // ---- service (fake SMAppService backend) ------------------------------------------------

    /// Rust: install/status/start/uninstall with a fake launchctl and a temp HOME. Now:
    /// register/status/start/unregister through a fake `AgentServiceBackend`.
    @Test func serviceInstallStatusUninstallWithFakeRegistration() throws {
        let env = try Env()
        let backend = FakeBackend(.notRegistered)
        let svc = { (args: [String]) in runInProcess(["service"] + args, env: env, endpoint: nil, backend: backend) }

        let before = svc(["status"]).success()
        #expect(before.stdout.contains("not registered"))
        #expect(before.stdout.contains("Agent: not running"))

        // Start refuses until the agent is registered, and never registers by itself.
        let startUnregistered = svc(["start"]).failure()
        #expect(startUnregistered.stderr.contains("dotfilesync service install"))
        #expect(backend.calls.withLock { $0 }.isEmpty)

        let install = svc(["install"]).success()
        #expect(install.stdout.contains("Registered:"))
        #expect(install.stdout.contains("The agent was not started"))
        #expect(backend.calls.withLock { $0 } == ["register"])
        #expect(svc(["install"]).success().stdout.contains("Already registered (unchanged)"))
        #expect(backend.calls.withLock { $0 } == ["register"], "install is idempotent")

        let status = svc(["status"]).success()
        #expect(status.stdout.contains("registered and enabled"))
        #expect(status.stdout.contains("Agent: not running"))
        let json = try svc(["status", "--json"]).success().json()
        #expect(json["registration"] as? String == "enabled")
        #expect(json["agent_running"] as? Bool == false)

        // Registered, but nothing answers (no launchd in tests): start explains.
        let start = svc(["start"]).failure()
        #expect(start.stderr.contains("not answering"))

        try FileManager.default.createDirectory(atPath: env.data.string, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: env.data.appending("keep-me").string))
        let uninstall = svc(["uninstall"]).success()
        #expect(uninstall.stdout.contains("Unregistered"))
        #expect(uninstall.stdout.contains("Kept agent state and logs"))
        #expect(backend.calls.withLock { $0 } == ["register", "unregister"])
        #expect(exists(env.data.appending("keep-me")), "uninstall keeps user data")
        #expect(svc(["uninstall"]).success().stdout.contains("was not registered"))
    }

    /// Rust: `service stop` shut down a daemon not managed by launchd. Now: `stop` sends
    /// `shutdown` to whatever agent answers.
    @Test func serviceStopShutsDownARunningAgent() throws {
        let env = try Env()
        let agent = try TestAgent(env)
        let endpoint = try agent.endpoint
        let status = try runInProcess(["service", "status", "--json"], env: env, endpoint: endpoint).success().json()
        #expect(status["agent_running"] as? Bool == true)
        #expect(status["agent_pid"] as? Int == Int(getpid()))
        let run = runInProcess(["service", "stop"], env: env, endpoint: endpoint).success()
        #expect(run.stdout.contains("shut down"))
        #expect(agent.service.isShutdownRequested)
        // With nothing running, stop says so.
        let none = runInProcess(["service", "stop"], env: env, endpoint: nil).success()
        #expect(none.stdout.contains("dotfilesyncd is not running."))
    }
}

/// Usage and help (H3).
@Suite struct CLIUsageTests {
    @Test func subcommandHelpWorks() throws {
        let env = try Env()
        for args in [
            ["scan"], ["status"], ["plan"], ["apply"], ["runs"], ["runs", "show"], ["import-brewfile"],
            ["jobs"], ["jobs", "watch"], ["jobs", "follow"], ["service"], ["service", "status"],
        ] {
            let run = runInProcess(args + ["--help"], env: env, endpoint: nil)
            #expect(run.code == 0, "\(args)")
            #expect(run.stdout.contains("USAGE: dotfilesync \(args[0])"), "\(args): \(run.stdout)")
        }
        let help = runInProcess(["help", "plan"], env: env, endpoint: nil)
        #expect(help.code == 0)
        #expect(help.stdout.contains("--profile"))
        let version = runInProcess(["--version"], env: env, endpoint: nil)
        #expect(version.stdout == "0.1.0\n")
    }

    @Test func unknownArgumentsAreUsageErrors() throws {
        let env = try Env()
        for args in [["bogus"], ["scan", "--nope"], ["scan", "--mode", "nope"], ["status"], ["jobs"], [], ["--data-dir"]] {
            let run = try env.cli(args).failure()
            #expect(run.code == 2, "\(args): \(run.code)")
            #expect(run.stderr.lowercased().contains("usage"), "\(args): \(run.stderr)")
            #expect(run.stdout.isEmpty)
        }
    }

    @Test func dataDirIsAcceptedBeforeOrAfterTheSubcommand() throws {
        let env = try Env()
        let other = env.tmp.appending("other")
        for args in [["--data-dir", other.string, "jobs", "list"], ["jobs", "list", "--data-dir=\(other.string)"]] {
            let run = try env.cli(args).failure()
            #expect(run.stderr.contains("not running"), "\(args)")
        }
    }
}
