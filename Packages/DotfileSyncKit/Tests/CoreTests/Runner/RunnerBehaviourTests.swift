import Foundation
import System
import Testing

@testable import Core

/// Swift-only checks of runner behaviour not covered by a dedicated Rust integration test.
@Suite("Runner behaviour")
struct RunnerBehaviourTests {
    // No Rust equivalent: missing binary maps to ExecutableNotFound with the Rust Display string.
    @Test func missingBinaryIsExecutableNotFound() {
        let runner = RealCommandRunner(timeout: .seconds(5))
        do {
            _ = try runner.run("/nonexistent/dotfilesync-no-such-binary", args: [])
            Issue.record("Expected ExecutableNotFound")
        } catch {
            #expect(error == .executableNotFound("/nonexistent/dotfilesync-no-such-binary"))
            #expect(error.description == "Executable '/nonexistent/dotfilesync-no-such-binary' was not found")
        }
    }

    // No Rust equivalent: successful output and inherited environment.
    @Test func successCapturesOutputAndInheritsEnvironment() throws {
        let out = try RealCommandRunner(timeout: .seconds(5))
            .run("/bin/sh", args: ["-c", "printf 'out'; printf 'err' >&2; test -n \"$PATH\" && echo ok"])
        #expect(out == CommandOutput(statusCode: 0, stdout: "outok\n", stderr: "err"))
    }

    // No Rust equivalent: a pre-set cancellation flag prevents the spawn.
    @Test func preCancelledDoesNotStart() {
        let flag = CancellationFlag()
        flag.cancel()
        let runner = RealCommandRunner(timeout: .seconds(5)).withCancellation(flag)
        #expect(throws: RunnerError.cancelled(program: "/bin/sh")) {
            try runner.run("/bin/sh", args: ["-c", "exit 0"])
        }
    }

    // No Rust equivalent: cancelling mid-run kills the child and throws Cancelled.
    @Test func cancelDuringRunKillsChild() {
        let flag = CancellationFlag()
        let runner = RealCommandRunner(timeout: .seconds(5)).withCancellation(flag)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) { flag.cancel() }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: RunnerError.cancelled(program: "/bin/sh")) {
            try runner.run("/bin/sh", args: ["-c", "sleep 3"])
        }
        #expect(clock.now - start < .milliseconds(1500))
    }

    // No Rust equivalent: signal termination reports code -1 (Rust `status.code().unwrap_or(-1)`).
    @Test func signalledChildReportsMinusOne() {
        #expect(throws: RunnerError.nonZeroExit(program: "/bin/sh", code: -1, stderr: "")) {
            try RealCommandRunner(timeout: .seconds(5)).run("/bin/sh", args: ["-c", "kill -9 $$"])
        }
    }

    // No Rust equivalent: Display strings of every RunnerError variant.
    @Test func errorDescriptionsMatchRust() {
        #expect(RunnerError.executionFailed(program: "p", message: "m").description
            == "Command 'p' failed to execute: m")
        #expect(RunnerError.timeout(program: "p", timeout: .seconds(15)).description
            == "Command 'p' timed out after 15s")
        #expect(RunnerError.cancelled(program: "p").description == "Command 'p' was cancelled")
        #expect(RunnerError.nonZeroExit(program: "p", code: 1, stderr: "boom").description
            == "Command 'p' exited with code 1: boom")
    }

    // No Rust equivalent: format_timeout branches.
    @Test func formatTimeoutBranches() {
        #expect(formatTimeout(.milliseconds(400)) == "400ms")
        #expect(formatTimeout(.milliseconds(0)) == "0ms")
        #expect(formatTimeout(.seconds(30)) == "30s")
        #expect(formatTimeout(.milliseconds(1500)) == "1.50s")
    }

    // No Rust equivalent: brew override lookup and PATH lookup.
    @Test func findExecutableHonoursBrewOverrideAndPath() throws {
        let tempDir = try TempDir()
        let fake = tempDir.url.appendingPathComponent("brew")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        let runner = RealCommandRunner().withBrewBinary(FilePath(fake.path))
        #expect(runner.findExecutable("brew") == FilePath(fake.path))
        #expect(runner.findExecutable("sh") != nil)
        #expect(runner.findExecutable("dotfilesync-definitely-missing") == nil)
    }

    // No Rust equivalent: mock runner lookup semantics.
    @Test func mockRunnerSemantics() {
        let ok = CommandOutput(statusCode: 0, stdout: "x", stderr: "")
        let mock = MockCommandRunner()
            .withExecutable("brew", FilePath("/mock/brew"))
            .withExecutable("none", nil)
            .withResponse("/mock/brew", args: ["a"], .success(ok))
        #expect(mock.findExecutable("brew") == FilePath("/mock/brew"))
        #expect(mock.findExecutable("none") == nil)
        #expect(mock.findExecutable("other") == nil)
        #expect((try? mock.run("/mock/brew", args: ["a"])) == ok)
        #expect((try? mock.runPath(FilePath("/mock/brew"), args: ["a"])) == ok)
        #expect(throws: RunnerError.executableNotFound("/mock/brew")) {
            try mock.run("/mock/brew", args: ["b"])
        }
    }
}
