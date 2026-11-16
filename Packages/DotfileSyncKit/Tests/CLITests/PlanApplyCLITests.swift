// Port of crates/dotfilesync-cli/tests/plan_apply_cli_tests.rs: `plan` is stable and runs
// without an agent; `apply` does not mutate unless asked and refuses without the agent.

import Foundation
import System
import Testing

private final class PlanEnv {
    let env: Env
    let repo: FilePath
    let manifest: FilePath
    let target: FilePath

    init() throws {
        env = try Env(.gitOnly)
        repo = env.tmp.appending("repo")
        try FileManager.default.createDirectory(atPath: repo.string, withIntermediateDirectories: true)
        try "desired\n".write(toFile: repo.appending("config.txt").string, atomically: true, encoding: .utf8)
        manifest = repo.appending("dotfilesync.toml")
        try "schema_version = 1\n\n[[files]]\nsource = \"config.txt\"\ntarget = \"~/.config/demo/config.txt\"\n"
            .write(toFile: manifest.string, atomically: true, encoding: .utf8)
        target = env.home.appending(".config/demo/config.txt")
    }

    var common: [String] {
        ["--manifest", manifest.string, "--home", env.home.string, "--repo-root", repo.string]
    }
}

@Suite struct PlanApplyCLITests {
    @Test func planJSONIsIdenticalAcrossTwoRuns() throws {
        let p = try PlanEnv()
        let args = ["plan", "--json"] + p.common + ["--mode", "standalone"]
        let first = try p.env.cli(args).success()
        let second = try p.env.cli(args).success()
        #expect(first.stdout == second.stdout)
        let actions = try first.json()["actions"] as? [Any]
        #expect(!(actions ?? []).isEmpty)
    }

    @Test func planHumanFormatListsEachAction() throws {
        let p = try PlanEnv()
        let run = try p.env.cli(["plan"] + p.common + ["--mode", "standalone"]).success()
        #expect(run.stdout.contains("[low] [rev] [copy]"))
        #expect(run.stdout.contains("action"))
    }

    /// Rust expected the hint `dotfilesync service start`; the hint now points at
    /// `dotfilesync service install` (SMAppService registration).
    @Test func applyWithoutAgentErrors() throws {
        let p = try PlanEnv()
        let run = try p.env.cli(["apply", "--yes"] + p.common).failure()
        #expect(run.stderr.contains("dotfilesync service install"))
        #expect(run.stderr.contains("not running"))
        #expect(!exists(p.target))
    }

    @Test func applyNonTTYWithoutYesDoesNotApply() throws {
        let p = try PlanEnv()
        let run = try p.env.cli(["apply"] + p.common).success()
        #expect(run.stderr.contains("dry-run"))
        #expect(run.stdout.contains("[low] [rev] [copy]"))
        #expect(!exists(p.target), "non-TTY apply without --yes must not create the target")
    }
}
