import Darwin
import Foundation
import System
import Testing

@testable import Core

/// Issue #11 AC4: promote/demote updates the manifest via a plan.
@Suite("ManifestChange")
struct ManifestChangeTests {
    static let manifestBody = """
        # my dotfiles — keep this comment
        schema_version = 1

        # Tracked files
        [[files]]
        source = "zsh/zshrc" # inline comment
        target = "~/.zshrc"
        description = "zsh"

        # trailing section comment
        [exclusions]
        paths = []
        patterns = ["*.backup.*"]

        """

    struct Fixture {
        let tmp: TempDir
        let repo: URL
        let home: URL
        let manifest: FilePath
        var homePath: FilePath { FilePath(home.path) }
        var repoPath: FilePath { FilePath(repo.path) }
        var backupRoot: FilePath { FilePath(tmp.url.appendingPathComponent("backups").path) }

        func homeFile(_ relative: String) -> FilePath { homePath.appending(relative) }

        func write(home relative: String, _ text: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: false, encoding: .utf8)
        }

        func input(_ change: ManifestChange) -> ManifestChangeInput {
            ManifestChangeInput(manifest: manifest, home: homePath, repoRoot: repoPath, change: change)
        }

        func context(_ runName: String, now: UInt64 = 1_700_000_000_000) -> ApplyContext {
            ApplyContext(
                runner: MockCommandRunner(),
                backupRoot: backupRoot,
                runDir: FilePath(tmp.url.appendingPathComponent("runs/\(runName)").path),
                allowSudo: false,
                now: { now }
            )
        }

        func manifestText() throws -> String {
            try String(contentsOfFile: manifest.string, encoding: .utf8)
        }
    }

    static func fixture() throws -> Fixture {
        let tmp = try TempDir()
        // Canonical paths so HOME-containment checks see no symlinked parents (/var → /private/var).
        let root = URL(fileURLWithPath: try canonicalize(FilePath(tmp.url.path)).string)
        let repo = root.appendingPathComponent("repo")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("zsh"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "zsh\n".write(to: repo.appendingPathComponent("zsh/zshrc"), atomically: false, encoding: .utf8)
        let manifestURL = repo.appendingPathComponent("dotfilesync.toml")
        try manifestBody.write(to: manifestURL, atomically: false, encoding: .utf8)
        return Fixture(tmp: tmp, repo: repo, home: home, manifest: FilePath(manifestURL.path))
    }

    static func failure(_ body: () throws -> Plan) -> String? {
        do {
            _ = try body()
            return nil
        } catch let error as OpError {
            return error.description
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Promote

    @Test func promoteFishConfigPlansAndAppliesPreservingComments() throws {
        let f = try Self.fixture()
        try f.write(home: ".config/fish/config.fish", "set -g fish_greeting\n")
        chmod(f.homeFile(".config/fish/config.fish").string, 0o600)
        let target = f.homeFile(".config/fish/config.fish")

        let plan = try planManifestChange(f.input(.promote(targets: [target])), hostname: "host")
        let again = try planManifestChange(f.input(.promote(targets: [target])), hostname: "host")
        #expect(plan.digest == again.digest)
        #expect(plan.actions.count == 1)
        #expect(plan.actions[0].risk == .medium)
        #expect(plan.actions[0].reversible)
        guard case let .promoteFile(t, source, manifest, entrySource, entryTarget, _) = plan.actions[0].kind else {
            Issue.record("expected promote_file")
            return
        }
        #expect(t == target)
        #expect(source == f.repoPath.appending("fish/config.fish"))
        #expect(manifest == f.manifest)
        #expect(entrySource == "fish/config.fish")
        #expect(entryTarget == "~/.config/fish/config.fish")
        #expect(try manifestChangeFingerprint(plan) == plan.stateFingerprint)

        let journal = try applyPlan(plan, context: f.context("promote"))
        #expect(journal.steps.map(\.status) == [.done])

        #expect(try String(contentsOfFile: source.string, encoding: .utf8) == "set -g fish_greeting\n")
        #expect(fileMode(source) == 0o600)
        let text = try f.manifestText()
        #expect(text.contains("# my dotfiles — keep this comment"))
        #expect(text.contains("source = \"zsh/zshrc\" # inline comment"))
        #expect(text.contains("# trailing section comment\n[exclusions]"))
        let parsed = try parseManifest(text)
        #expect(parsed.files.map(\.target) == ["~/.zshrc", "~/.config/fish/config.fish"])
        #expect(parsed.files.last?.source == "fish/config.fish")
        #expect(parsed.exclusions.patterns == ["*.backup.*"])

        let backup = try #require(journal.steps[0].backupPath)
        #expect(try String(contentsOfFile: backup.string, encoding: .utf8) == Self.manifestBody)
        // Machine file untouched.
        #expect(try String(contentsOfFile: target.string, encoding: .utf8) == "set -g fish_greeting\n")
    }

    @Test func promoteInsertsAfterLastFilesTableNotAtEnd() throws {
        let f = try Self.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        _ = try applyPlan(plan, context: f.context("insert"))
        let text = try f.manifestText()
        let entry = try #require(text.range(of: "source = \"gitconfig\""))
        let exclusions = try #require(text.range(of: "[exclusions]"))
        #expect(entry.lowerBound < exclusions.lowerBound)
        #expect(try parseManifest(text).files.last == TrackedFile(source: "gitconfig", target: "~/.gitconfig"))
    }

    @Test func secretLikeTargetsAreRefusedWithoutReading() throws {
        let f = try Self.fixture()
        try f.write(home: ".ssh/config", "Host *\n")
        try f.write(home: ".config/gh/hosts.yml", "token\n")
        for relative in [".ssh/config", ".config/gh/hosts.yml"] {
            let target = f.homeFile(relative)
            // Unreadable: a read attempt would fail with EACCES instead of the classification message.
            chmod(target.string, 0o000)
            defer { chmod(target.string, 0o600) }
            let message = try #require(Self.failure {
                try planManifestChange(f.input(.promote(targets: [target])), hostname: "host")
            })
            #expect(message.contains("secret-like"), "\(relative): \(message)")
        }
        // A directory that is itself secret-like is refused before listing.
        let message = try #require(Self.failure {
            try planManifestChange(f.input(.promote(targets: [f.homeFile(".ssh")])), hostname: "host")
        })
        #expect(message.contains("secret-like"))
    }

    @Test func alreadyManagedPromoteIsRefused() throws {
        let f = try Self.fixture()
        try f.write(home: ".zshrc", "zsh\n")
        let message = try #require(Self.failure {
            try planManifestChange(f.input(.promote(targets: [f.homeFile(".zshrc")])), hostname: "host")
        })
        #expect(message.contains("already managed"))
    }

    @Test func promoteRefusesTargetsOutsideHomeSymlinksAndSourceCollisions() throws {
        let f = try Self.fixture()
        let outside = f.repoPath.appending("zsh/zshrc")
        #expect(Self.failure {
            try planManifestChange(f.input(.promote(targets: [outside])), hostname: "host")
        }?.contains("not inside HOME") == true)

        try f.write(home: "real.conf", "x\n")
        symlink(f.homeFile("real.conf").string, f.homeFile("link.conf").string)
        #expect(Self.failure {
            try planManifestChange(f.input(.promote(targets: [f.homeFile("link.conf")])), hostname: "host")
        }?.contains("symlink") == true)

        // `~/zsh/zshrc` maps to repository `zsh/zshrc`, already the source of `~/.zshrc`.
        try f.write(home: "zsh/zshrc", "other\n")
        #expect(Self.failure {
            try planManifestChange(f.input(.promote(targets: [f.homeFile("zsh/zshrc")])), hostname: "host")
        }?.contains("already the source") == true)
    }

    @Test func targetChangedAfterPlanFailsClosedAtApply() throws {
        let f = try Self.fixture()
        try f.write(home: ".config/fish/config.fish", "v1\n")
        let target = f.homeFile(".config/fish/config.fish")
        let plan = try planManifestChange(f.input(.promote(targets: [target])), hostname: "host")
        try f.write(home: ".config/fish/config.fish", "v2\n")
        #expect(try manifestChangeFingerprint(plan) != plan.stateFingerprint)

        #expect(throws: ApplyError.self) { try applyPlan(plan, context: f.context("stale")) }
        do {
            _ = try applyPlan(plan, context: f.context("stale2"))
        } catch let ApplyError.stepFailed(_, message, _) {
            #expect(message.contains("changed after the plan"))
        }
        #expect(try f.manifestText() == Self.manifestBody)
        #expect(!FileManager.default.fileExists(atPath: f.repoPath.appending("fish/config.fish").string))
    }

    @Test func manifestChangedAfterPlanChangesFingerprint() throws {
        let f = try Self.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        try (Self.manifestBody + "# edited\n").write(toFile: f.manifest.string, atomically: false, encoding: .utf8)
        #expect(try manifestChangeFingerprint(plan) != plan.stateFingerprint)
    }

    @Test func directoryPromoteExpandsSortedAndSkipsExcluded() throws {
        let f = try Self.fixture()
        try f.write(home: ".config/nvim/init.lua", "-- init\n")
        try f.write(home: ".config/nvim/lua/plugins.lua", "return {}\n")
        try f.write(home: ".config/nvim/lazy-lock.json", "{}\n")
        try f.write(home: ".config/nvim/secret_token.txt", "s\n")
        try f.write(home: ".config/nvim/cache/x.lua", "c\n")
        try f.write(home: ".config/nvim/local.fish", "l\n")
        symlink(f.homeFile(".config/nvim/init.lua").string, f.homeFile(".config/nvim/alias.lua").string)

        let dir = f.homeFile(".config/nvim")
        let plan = try planManifestChange(f.input(.promote(targets: [dir])), hostname: "host")
        let targets = plan.actions.compactMap { action -> String? in
            if case let .promoteFile(_, _, _, _, entryTarget, _) = action.kind { return entryTarget }
            return nil
        }
        #expect(targets == ["~/.config/nvim/init.lua", "~/.config/nvim/lua/plugins.lua"])
        #expect(plan.actions.map(\.id) == ["a-001", "a-002"])
        #expect(try planManifestChange(f.input(.promote(targets: [dir])), hostname: "host").digest == plan.digest)

        let journal = try applyPlan(plan, context: f.context("dir"))
        #expect(journal.steps.map(\.status) == [.done, .done])
        let parsed = try parseManifest(try f.manifestText())
        #expect(parsed.files.map(\.source) == ["zsh/zshrc", "nvim/init.lua", "nvim/lua/plugins.lua"])
    }

    @Test func rerunningACompletedPromoteDoesNotDuplicateTheEntry() throws {
        let f = try Self.fixture()
        try f.write(home: ".gitconfig", "[user]\n")
        let plan = try planManifestChange(f.input(.promote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        let ctx = f.context("resume")
        _ = try applyPlan(plan, context: ctx)
        // Simulate a crash after the step ran but before `done` was journaled.
        try JournalStore.open(runDir: ctx.runDir).appendStep(
            StepRecord(actionId: "a-001", status: .running, atMs: 1)
        )
        let journal = try resumeRun(runDir: ctx.runDir, plan: plan, context: ctx)
        #expect(journal.steps.map(\.status) == [.done])
        let parsed = try parseManifest(try f.manifestText())
        #expect(parsed.files.filter { $0.target == "~/.gitconfig" }.count == 1)
    }

    // MARK: - Demote

    @Test func demoteRemovesEntryAndLeavesMachineFile() throws {
        let f = try Self.fixture()
        try f.write(home: ".config/fish/config.fish", "fish\n")
        let target = f.homeFile(".config/fish/config.fish")
        let promote = try planManifestChange(f.input(.promote(targets: [target])), hostname: "host")
        _ = try applyPlan(promote, context: f.context("p"))
        let afterPromote = try f.manifestText()

        let plan = try planManifestChange(f.input(.demote(targets: [target])), hostname: "host")
        #expect(plan.digest == (try planManifestChange(f.input(.demote(targets: [target])), hostname: "host")).digest)
        guard case let .demoteFile(t, manifest, entryTarget) = plan.actions[0].kind else {
            Issue.record("expected demote_file")
            return
        }
        #expect(t == target)
        #expect(manifest == f.manifest)
        #expect(entryTarget == "~/.config/fish/config.fish")

        let journal = try applyPlan(plan, context: f.context("d", now: 1_700_000_100_000))
        #expect(journal.steps.map(\.status) == [.done])
        #expect(try f.manifestText() == Self.manifestBody)
        #expect(try String(contentsOfFile: target.string, encoding: .utf8) == "fish\n")
        #expect(FileManager.default.fileExists(atPath: f.repoPath.appending("fish/config.fish").string))
        let backup = try #require(journal.steps[0].backupPath)
        #expect(try String(contentsOfFile: backup.string, encoding: .utf8) == afterPromote)
    }

    @Test func demoteOfExistingCommentedEntryKeepsOtherComments() throws {
        let f = try Self.fixture()
        let plan = try planManifestChange(f.input(.demote(targets: [f.homeFile(".zshrc")])), hostname: "host")
        _ = try applyPlan(plan, context: f.context("d"))
        let text = try f.manifestText()
        #expect(text.contains("# my dotfiles — keep this comment"))
        #expect(text.contains("# trailing section comment\n[exclusions]"))
        #expect(!text.contains("zsh/zshrc"))
        #expect(try parseManifest(text).files.isEmpty)
    }

    @Test func demoteRefusesUnmanagedTarget() throws {
        let f = try Self.fixture()
        let message = try #require(Self.failure {
            try planManifestChange(f.input(.demote(targets: [f.homeFile(".gitconfig")])), hostname: "host")
        })
        #expect(message.contains("not managed"))
    }

    // MARK: - Encoding

    @Test func newActionKindsRoundTripThroughJSON() throws {
        let kinds: [ActionKind] = [
            .promoteFile(
                target: FilePath("/h/.config/fish/config.fish"),
                source: FilePath("/r/fish/config.fish"),
                manifest: FilePath("/r/dotfilesync.toml"),
                entrySource: "fish/config.fish",
                entryTarget: "~/.config/fish/config.fish",
                targetSha256: "abc"
            ),
            .demoteFile(target: FilePath("/h/.zshrc"), manifest: FilePath("/r/dotfilesync.toml"), entryTarget: "~/.zshrc"),
        ]
        for kind in kinds {
            let json = try jsonStringCompact(kind)
            #expect(try JSONDecoder().decode(ActionKind.self, from: Data(json.utf8)) == kind)
        }
        #expect(try jsonStringCompact(kinds[1])
            == #"{"kind":"demote_file","target":"/h/.zshrc","manifest":"/r/dotfilesync.toml","entry_target":"~/.zshrc"}"#)
        #expect(try jsonStringCompact(kinds[0]).hasPrefix(#"{"kind":"promote_file","target":"#))
        let input = ManifestChangeInput(
            manifest: FilePath("/r/m.toml"), home: FilePath("/h"), change: .promote(targets: [FilePath("/h/a")])
        )
        #expect(try JSONDecoder().decode(ManifestChangeInput.self, from: Data(try jsonStringCompact(input).utf8)) == input)
    }

    @Test func promotedSourceMappingIsDeterministic() {
        #expect(promotedSourcePath(forHomeRelative: FilePath(".config/fish/config.fish")) == FilePath("fish/config.fish"))
        #expect(promotedSourcePath(forHomeRelative: FilePath(".gitconfig")) == FilePath("gitconfig"))
        #expect(promotedSourcePath(forHomeRelative: FilePath(".local/bin/tool")) == FilePath("local/bin/tool"))
        #expect(promotedSourcePath(forHomeRelative: FilePath("Library/x.plist")) == FilePath("Library/x.plist"))
    }
}
