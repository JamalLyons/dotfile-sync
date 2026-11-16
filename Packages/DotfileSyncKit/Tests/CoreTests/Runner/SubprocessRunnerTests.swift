import Darwin
import Foundation
import System
import Testing

@testable import Core

/// Ports of crates/dotfilesync-core/tests/subprocess_runner_tests.rs.
@Suite("Subprocess runner")
struct SubprocessRunnerTests {
    private func timed<T>(_ body: () throws(RunnerError) -> T) -> (Result<T, RunnerError>, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let result: Result<T, RunnerError>
        do {
            result = .success(try body())
        } catch {
            result = .failure(error)
        }
        return (result, clock.now - start)
    }

    /// Kills the PID recorded in `pidFile` (and optionally its group) when the test ends.
    private final class ProcessCleanupGuard {
        let pidFile: URL
        let killGroup: Bool

        init(pidFile: URL, killGroup: Bool) {
            self.pidFile = pidFile
            self.killGroup = killGroup
        }

        var recordedPID: pid_t? {
            guard let content = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
            return pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        deinit {
            if let pid = recordedPID {
                if killGroup { _ = kill(-pid, SIGKILL) }
                _ = kill(pid, SIGKILL)
            }
        }
    }

    private func expectTimeout<T>(_ result: Result<T, RunnerError>) {
        guard case .failure(.timeout) = result else {
            Issue.record("Expected Timeout error, got: \(result)")
            return
        }
    }

    // Ports test_real_runner_large_stdout_does_not_deadlock
    @Test func largeStdoutDoesNotDeadlock() throws {
        let runner = RealCommandRunner(timeout: .seconds(5))
        let out = try runner.run("/bin/sh", args: ["-c", "head -c 150000 /dev/zero | tr '\\0' 'A'"])
        #expect(out.statusCode == 0)
        #expect(out.stdout.utf8.count == 150_000)
        #expect(out.stderr.isEmpty)
    }

    // Ports test_real_runner_large_stderr_does_not_deadlock
    @Test func largeStderrDoesNotDeadlock() throws {
        let runner = RealCommandRunner(timeout: .seconds(5))
        let out = try runner.run("/bin/sh", args: ["-c", "head -c 150000 /dev/zero | tr '\\0' 'B' >&2"])
        #expect(out.statusCode == 0)
        #expect(out.stderr.utf8.count == 150_000)
    }

    // Ports test_real_runner_nonzero_exit
    @Test func nonZeroExit() {
        let runner = RealCommandRunner(timeout: .seconds(5))
        let (result, _) = timed { () throws(RunnerError) in
            try runner.run("/bin/sh", args: ["-c", "echo 'failed step' >&2; exit 42"])
        }
        guard case .failure(.nonZeroExit(_, let code, let stderr)) = result else {
            Issue.record("Expected NonZeroExit error, got: \(result)")
            return
        }
        #expect(code == 42)
        #expect(stderr.contains("failed step"))
    }

    // Ports test_real_runner_timeout_reports_subsecond_duration
    @Test func timeoutReportsSubsecondDuration() {
        let timeout = Duration.milliseconds(400)
        let runner = RealCommandRunner(timeout: timeout)
        let (result, elapsed) = timed { () throws(RunnerError) in
            try runner.run("/bin/sh", args: ["-c", "sleep 3"])
        }
        #expect(elapsed >= .milliseconds(350), "Elapsed time too short: \(elapsed)")
        #expect(elapsed < .milliseconds(1800), "Elapsed time too long (descendant not terminated): \(elapsed)")

        guard case .failure(.timeout(let program, let errTimeout)) = result else {
            Issue.record("Expected Timeout error, got: \(result)")
            return
        }
        #expect(program == "/bin/sh")
        #expect(errTimeout == timeout)
        let message = RunnerError.timeout(program: program, timeout: errTimeout).description
        #expect(message.contains("400ms"), "Expected subsecond duration '400ms' in error message, got: '\(message)'")
        #expect(!message.contains("after 0s"), "Should not truncate timeout to 0s: '\(message)'")
    }

    // Ports test_real_runner_descendant_holding_pipes_open_terminates_at_deadline
    @Test func descendantHoldingPipesOpenTerminatesAtDeadline() {
        let runner = RealCommandRunner(timeout: .milliseconds(400))
        let (result, elapsed) = timed { () throws(RunnerError) in
            try runner.run("/bin/sh", args: ["-c", "sleep 3 & wait"])
        }
        #expect(elapsed >= .milliseconds(350), "Elapsed time too short: \(elapsed)")
        #expect(elapsed < .milliseconds(1800), "Timeout cleanup blocked on descendant holding pipes open! Took \(elapsed)")
        expectTimeout(result)
    }

    // Ports test_real_runner_background_descendant_holding_pipes_open
    @Test func backgroundDescendantHoldingPipesOpen() {
        let runner = RealCommandRunner(timeout: .milliseconds(400))
        let (result, elapsed) = timed { () throws(RunnerError) in
            try runner.run("/bin/sh", args: ["-c", "(sleep 3 &) ; exit 0"])
        }
        #expect(elapsed >= .milliseconds(350), "Elapsed time too short: \(elapsed)")
        #expect(elapsed < .milliseconds(1800), "Full call must be bounded by deadline: took \(elapsed)")
        expectTimeout(result)
    }

    // Ports test_real_runner_detached_session_descendant_is_terminated
    @Test func detachedSessionDescendantIsTerminated() throws {
        let tempDir = try TempDir()
        let pidFile = tempDir.url.appendingPathComponent("detached_session_grandchild.pid")
        let guardian = ProcessCleanupGuard(pidFile: pidFile, killGroup: true)
        let pidFileStr = pidFile.path
        let script = """
            import subprocess, sys, time, os
            pid_file = "\(pidFileStr)"
            gc_code = f\"\"\"
            import os, time
            os.setsid()
            with open('\(pidFileStr)', 'w') as f:
                f.write(str(os.getpid()) + '\\\\n')
                f.flush()
            time.sleep(3)
            \"\"\"
            p = subprocess.Popen([sys.executable, "-c", gc_code])
            p.wait()
            """

        let runner = RealCommandRunner(timeout: .milliseconds(400))
        let (result, elapsed) = timed { () throws(RunnerError) in
            try runner.run("python3", args: ["-c", script])
        }
        #expect(elapsed >= .milliseconds(350), "Elapsed time too short: \(elapsed)")
        #expect(elapsed < .milliseconds(1800), "Full call must terminate detached descendants at deadline: took \(elapsed)")
        expectTimeout(result)

        if let pid = guardian.recordedPID {
            #expect(kill(pid, 0) == -1, "Detached session grandchild (PID \(pid)) should have been terminated by runner")
        }
    }

    private func parentExitsFirstScript(pidFile: String, closing stream: String) -> String {
        """
        import os, sys, time
        pid_file = "\(pidFile)"
        pid = os.fork()
        if pid == 0:
            os.setsid()
            with open(pid_file, 'w') as f:
                f.write(str(os.getpid()) + '\\n')
                f.flush()
            sys.\(stream).close()
            time.sleep(3)
            sys.exit(0)
        while not (os.path.exists(pid_file) and os.path.getsize(pid_file) > 0):
            time.sleep(0.005)
        sys.exit(0)
        """
    }

    private func runParentExitsFirst(pidFileName: String, closing stream: String) throws {
        let tempDir = try TempDir()
        let pidFile = tempDir.url.appendingPathComponent(pidFileName)
        let guardian = ProcessCleanupGuard(pidFile: pidFile, killGroup: false)
        let script = parentExitsFirstScript(pidFile: pidFile.path, closing: stream)
        let timeout = Duration.milliseconds(400)
        let runner = RealCommandRunner(timeout: timeout)
        let (result, elapsed) = timed { () throws(RunnerError) in
            try runner.run("python3", args: ["-c", script])
        }
        withExtendedLifetime(guardian) {}
        #expect(elapsed >= .milliseconds(350), "Elapsed time too short: \(elapsed)")
        #expect(elapsed < .milliseconds(2000), "Full call must be bounded by deadline: took \(elapsed)")
        guard case .failure(.timeout(let program, let errTimeout)) = result else {
            Issue.record("Expected Timeout error, got: \(result)")
            return
        }
        #expect(program == "python3")
        #expect(errTimeout == timeout)
    }

    // Ports test_real_runner_parent_exits_first_detached_descendant_holding_stdout
    @Test func parentExitsFirstDetachedDescendantHoldingStdout() throws {
        try runParentExitsFirst(pidFileName: "grandchild_stdout.pid", closing: "stderr")
    }

    // Ports test_real_runner_parent_exits_first_detached_descendant_holding_stderr
    @Test func parentExitsFirstDetachedDescendantHoldingStderr() throws {
        try runParentExitsFirst(pidFileName: "grandchild_stderr.pid", closing: "stdout")
    }

    // Ports test_real_runner_non_utf8_executable_path
    @Test func nonUTF8ExecutablePath() throws {
        let tempDir = try TempDir()
        var bytes = Array((tempDir.path + "/mock_bin_").utf8).map { CChar(bitPattern: $0) }
        bytes.append(CChar(bitPattern: 0xFF))
        bytes.append(0)
        let scriptPath = FilePath(platformString: bytes)

        let content = "#!/bin/sh\necho 'non-utf8 ok'\n"
        let fd = scriptPath.withPlatformString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o755) }
        if fd >= 0 {
            // Platform supports non-UTF-8 file names (Linux-like filesystems).
            _ = content.withCString { write(fd, $0, strlen($0)) }
            _ = close(fd)
            let out = try RealCommandRunner().runPath(scriptPath, args: [])
            #expect(out.statusCode == 0)
            #expect(out.stdout.contains("non-utf8 ok"))
        } else {
            let err = errno
            // APFS rejects invalid UTF-8 names with EILSEQ (92) or EINVAL.
            #expect(err == EILSEQ || err == EINVAL, "Unexpected filesystem error: \(err)")
            let (result, _) = timed { () throws(RunnerError) in
                try RealCommandRunner().runPath(scriptPath, args: [])
            }
            switch result {
            case .failure(.executableNotFound(let program)), .failure(.executionFailed(let program, _)):
                #expect(!program.isEmpty)
            default:
                Issue.record("Expected ExecutableNotFound or ExecutionFailed, got: \(result)")
            }
        }
    }
}
