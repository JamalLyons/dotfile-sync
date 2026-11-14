import Darwin
import Foundation
import Synchronization
import System

/// Runs real subprocesses with an overall call deadline.
///
/// Semantics (ported from the Rust `RealCommandRunner`):
/// - The child is spawned with `posix_spawnp` into its own process group (PGID = child PID),
///   inheriting the caller's environment and stdin; stdout and stderr are piped.
/// - Both pipes are drained concurrently by reader threads using non-blocking reads and
///   15 ms `poll` slices, so large output never deadlocks and readers notice stop requests.
/// - The timeout covers the whole call: spawn, wait, and draining output. When the direct child
///   exits but a descendant keeps a pipe open, the call still ends at the deadline.
/// - On timeout or cancellation the runner SIGKILLs the process group, the child, and every
///   descendant (and its group) discovered while running via `proc_listchildpids` — including
///   descendants that called `setsid(2)` before the child exited. Descendants that detach after
///   the child has been reaped cannot be discovered; reader cleanup stays bounded regardless.
/// - Output is not size-capped (matches Rust); bytes are decoded as lossy UTF-8.
public struct RealCommandRunner: CommandRunner {
    /// Overall per-call deadline.
    public let timeout: Duration
    private var brewBinOverride: FilePath?
    private var cancel: CancellationFlag?

    /// Creates a runner with the given deadline. The Rust default is 30 seconds.
    public init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    /// Prefer `path` when resolving `brew` (checked before `DOTFILESYNC_BREW_BIN` and `PATH`).
    public func withBrewBinary(_ path: FilePath) -> RealCommandRunner {
        var copy = self
        copy.brewBinOverride = path
        return copy
    }

    /// Attaches a cancellation flag. When the flag becomes `true` while a command is running,
    /// the runner terminates the processes it owns (same cleanup as the timeout path) and throws
    /// ``RunnerError/cancelled(program:)``. A command is not started if the flag is already set.
    public func withCancellation(_ flag: CancellationFlag) -> RealCommandRunner {
        var copy = self
        copy.cancel = flag
        return copy
    }

    private var isCancelled: Bool {
        cancel?.isCancelled ?? false
    }

    public func findExecutable(_ name: String) -> FilePath? {
        if name == "brew" {
            if let overridePath = brewBinOverride, isRegularFile(overridePath) {
                return overridePath
            }
            if let envPath = ProcessInfo.processInfo.environment["DOTFILESYNC_BREW_BIN"] {
                let path = FilePath(envPath)
                if isRegularFile(path) {
                    return path
                }
            }
        }

        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":", omittingEmptySubsequences: false) {
                // `pushing` replaces the base when `name` is absolute, like Rust's `Path::join`.
                let candidate = FilePath(String(dir)).pushing(FilePath(name))
                if isRegularFile(candidate) {
                    return candidate
                }
            }
        }

        if name == "brew" {
            for location in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
                let path = FilePath(location)
                if isRegularFile(path) {
                    return path
                }
            }
        }

        return nil
    }

    public func run(_ program: String, args: [String]) throws(RunnerError) -> CommandOutput {
        try runPath(FilePath(program), args: args)
    }

    public func runPath(_ program: FilePath, args: [String]) throws(RunnerError) -> CommandOutput {
        let clock = ContinuousClock()
        let start = clock.now
        let programDisplay = program.string
        func elapsed() -> Duration { clock.now - start }

        if isCancelled {
            throw .cancelled(program: programDisplay)
        }

        let execPath = findExecutable(program.string) ?? program

        let spawned: SpawnedChild
        do {
            spawned = try spawnChild(execPath: execPath, args: args)
        } catch {
            if error.code == ENOENT {
                throw .executableNotFound(programDisplay)
            }
            throw .executionFailed(program: programDisplay, message: error.message)
        }

        let child = ChildProcess(pid: spawned.pid)
        var tracked: [pid_t] = []

        // Readers own the read ends from here on and close them when they finish.
        let stdoutReader = PipeReader(fd: spawned.stdoutFD)
        let stderrReader = PipeReader(fd: spawned.stderrFD)
        for (reader, name) in [(stdoutReader, "stdout"), (stderrReader, "stderr")] {
            if let errno = setNonBlocking(reader.fd) {
                child.killOwned(tracked: tracked)
                _ = close(stdoutReader.fd)
                _ = close(stderrReader.fd)
                throw .executionFailed(
                    program: programDisplay,
                    message: "Failed setting non-blocking mode on \(name): \(osErrorString(errno))"
                )
            }
        }
        stdoutReader.start()
        stderrReader.start()

        func abort() {
            stdoutReader.requestStop()
            stderrReader.requestStop()
            child.killOwned(tracked: tracked)
            stdoutReader.joinBounded(.milliseconds(50))
            stderrReader.joinBounded(.milliseconds(50))
        }

        var exitStatus: Int32?
        waitLoop: while elapsed() < timeout {
            if isCancelled {
                abort()
                throw .cancelled(program: programDisplay)
            }
            collectChildPIDs(root: spawned.pid, tracked: &tracked)
            let remaining = timeout - elapsed()
            let slice = min(Duration.milliseconds(20), remaining)
            let sliceEnd = clock.now + slice
            repeat {
                switch child.tryWait() {
                case .exited(let status):
                    exitStatus = status
                    break waitLoop
                case .running:
                    break
                case .failed(let errno):
                    abort()
                    throw .executionFailed(program: programDisplay, message: osErrorString(errno))
                }
                let left = sliceEnd - clock.now
                if left > .zero {
                    sleepFor(min(left, .milliseconds(2)))
                }
            } while clock.now < sliceEnd
        }

        guard let status = exitStatus else {
            // Deadline reached while the direct child was still running.
            abort()
            throw .timeout(program: programDisplay, timeout: timeout)
        }

        // Direct child exited; wait for readers, bounded by the overall call deadline so a
        // lingering descendant holding a pipe open cannot block the caller.
        while !stdoutReader.isFinished || !stderrReader.isFinished {
            if isCancelled || elapsed() >= timeout {
                let cancelled = isCancelled
                abort()
                if cancelled {
                    throw .cancelled(program: programDisplay)
                }
                throw .timeout(program: programDisplay, timeout: timeout)
            }
            sleepFor(.milliseconds(2))
        }

        let stdoutResult = stdoutReader.result()
        if let errno = stdoutResult.errno {
            throw .executionFailed(
                program: programDisplay, message: "Failed reading stdout: \(osErrorString(errno))")
        }
        let stderrResult = stderrReader.result()
        if let errno = stderrResult.errno {
            throw .executionFailed(
                program: programDisplay, message: "Failed reading stderr: \(osErrorString(errno))")
        }

        let stdout = String(decoding: stdoutResult.bytes, as: UTF8.self)
        let stderr = String(decoding: stderrResult.bytes, as: UTF8.self)
        let exited = (status & 0x7f) == 0
        let code: Int32 = exited ? (status >> 8) & 0xff : -1

        guard exited && code == 0 else {
            throw .nonZeroExit(program: programDisplay, code: code, stderr: stderr)
        }
        return CommandOutput(statusCode: code, stdout: stdout, stderr: stderr)
    }
}

// MARK: - Spawning

private struct SpawnError: Error {
    var code: Int32
    var message: String { osErrorString(code) }
}

private struct SpawnedChild {
    var pid: pid_t
    var stdoutFD: Int32
    var stderrFD: Int32
}

/// Rust `io::Error` display format: `"<strerror> (os error N)"`.
private func osErrorString(_ errno: Int32) -> String {
    "\(String(cString: strerror(errno))) (os error \(errno))"
}

/// Spawns `execPath` (PATH-searched when it has no slash, like Rust's `Command`) in a new process
/// group. `POSIX_SPAWN_CLOEXEC_DEFAULT` ensures only stdin and the two pipe write ends reach the
/// child, so concurrently spawned children never inherit (and hold open) another call's pipes.
private func spawnChild(execPath: FilePath, args: [String]) throws(SpawnError) -> SpawnedChild {
    var outPipe: [Int32] = [-1, -1]
    var errPipe: [Int32] = [-1, -1]
    guard pipe(&outPipe) == 0 else { throw SpawnError(code: errno) }
    guard pipe(&errPipe) == 0 else {
        let saved = errno
        closeAll(outPipe)
        throw SpawnError(code: saved)
    }
    for fd in outPipe + errPipe {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    var actions: posix_spawn_file_actions_t?
    var attrs: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attrs)
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attrs)
    }
    posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
    // Like Rust's std `Command`: reset SIGPIPE to its default action and clear the signal mask
    // so the child behaves normally even if the host process ignores SIGPIPE.
    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    sigaddset(&defaultSignals, SIGPIPE)
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    posix_spawnattr_setsigdefault(&attrs, &defaultSignals)
    posix_spawnattr_setsigmask(&attrs, &emptyMask)
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
        | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attrs, Int16(flags))
    posix_spawnattr_setpgroup(&attrs, 0)

    var pid: pid_t = 0
    let argv0 = execPath.string
    let rc: Int32 = execPath.withCString { pathPtr in
        withCStringArray([argv0] + args) { argv in
            posix_spawnp(&pid, pathPtr, &actions, &attrs, argv, environ)
        }
    }
    _ = close(outPipe[1])
    _ = close(errPipe[1])
    guard rc == 0 else {
        _ = close(outPipe[0])
        _ = close(errPipe[0])
        throw SpawnError(code: rc)
    }
    return SpawnedChild(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0])
}

private func closeAll(_ fds: [Int32]) {
    for fd in fds where fd >= 0 {
        _ = close(fd)
    }
}

private func withCStringArray<R>(
    _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
    let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    return pointers.withUnsafeBufferPointer { buffer in
        // `buffer.baseAddress` is non-nil: the array always holds the trailing nil terminator.
        guard let base = buffer.baseAddress else { preconditionFailure("empty argv buffer") }
        return body(base)
    }
}

private func setNonBlocking(_ fd: Int32) -> Int32? {
    let flags = fcntl(fd, F_GETFL)
    if flags < 0 { return errno }
    if fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 { return errno }
    return nil
}

private func isRegularFile(_ path: FilePath) -> Bool {
    var info = stat()
    let rc = path.withCString { stat($0, &info) }
    return rc == 0 && (info.st_mode & S_IFMT) == S_IFREG
}

private func sleepFor(_ duration: Duration) {
    let (seconds, attoseconds) = duration.components
    var request = timespec(tv_sec: Int(seconds), tv_nsec: Int(attoseconds / 1_000_000_000))
    var remaining = timespec()
    while nanosleep(&request, &remaining) == -1 && errno == EINTR {
        request = remaining
    }
}

// MARK: - Child process bookkeeping

private enum WaitResult {
    case running
    case exited(Int32)
    case failed(Int32)
}

/// Tracks the direct child so it is reaped exactly once. Used only on the calling thread.
private final class ChildProcess {
    let pid: pid_t
    private var reaped = false

    init(pid: pid_t) {
        self.pid = pid
    }

    func tryWait() -> WaitResult {
        var status: Int32 = 0
        while true {
            let rc = waitpid(pid, &status, WNOHANG)
            if rc == pid {
                reaped = true
                return .exited(status)
            }
            if rc == 0 { return .running }
            if errno == EINTR { continue }
            return .failed(errno)
        }
    }

    /// SIGKILLs the process group created at spawn, the child, and every tracked descendant
    /// (and its group), then reaps the child if it has not been reaped yet.
    func killOwned(tracked: [pid_t]) {
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        for descendant in tracked where descendant > 0 && descendant != pid {
            _ = kill(-descendant, SIGKILL)
            _ = kill(descendant, SIGKILL)
        }
        guard !reaped else { return }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        reaped = true
    }
}

/// Recursively discovers descendants of `root` with libproc's `proc_listchildpids`, including
/// descendants that moved into a new session or process group.
private func collectChildPIDs(root: pid_t, tracked: inout [pid_t]) {
    var toCheck: [pid_t] = [root]
    var checked: Set<pid_t> = []
    var buffer = [pid_t](repeating: 0, count: 128)
    let bufferBytes = Int32(buffer.count * MemoryLayout<pid_t>.stride)

    while let parent = toCheck.popLast() {
        guard checked.insert(parent).inserted else { continue }
        let count = buffer.withUnsafeMutableBytes { raw in
            proc_listchildpids(parent, raw.baseAddress, bufferBytes)
        }
        guard count > 0 else { continue }
        for child in buffer.prefix(min(Int(count), buffer.count))
        where child > 0 && !tracked.contains(child) {
            tracked.append(child)
            toCheck.append(child)
        }
    }
}

// MARK: - Pipe readers

/// Drains one pipe on a dedicated thread (Rust: `spawn_reader_thread`).
///
/// Cross-thread state lives in `Atomic`/`Mutex` from the Synchronization module, so the type is
/// genuinely `Sendable`. The reader thread closes `fd` when it finishes.
private final class PipeReader: Sendable {
    struct Output: Sendable {
        var bytes: [UInt8] = []
        var errno: Int32?
    }

    let fd: Int32
    private let stop = Atomic<Bool>(false)
    private let finished = Atomic<Bool>(false)
    private let output = Mutex(Output())

    init(fd: Int32) {
        self.fd = fd
    }

    var isFinished: Bool { finished.load(ordering: .acquiring) }

    func requestStop() {
        stop.store(true, ordering: .sequentiallyConsistent)
    }

    func start() {
        let thread = Thread { [self] in
            let result = drain()
            output.withLock { $0 = result }
            _ = close(fd)
            finished.store(true, ordering: .releasing)
        }
        thread.start()
    }

    /// Requests a stop and waits up to `maxWait` for the thread to finish.
    func joinBounded(_ maxWait: Duration) {
        requestStop()
        let clock = ContinuousClock()
        let deadline = clock.now + maxWait
        while !isFinished && clock.now < deadline {
            sleepFor(.milliseconds(2))
        }
    }

    /// The drained bytes; call only after ``isFinished`` is true.
    func result() -> Output {
        output.withLock { $0 }
    }

    private func drain() -> Output {
        var result = Output()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while !stop.load(ordering: .relaxed) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = poll(&pfd, 1, 15)
            if ready < 0 {
                if errno == EINTR { continue }
                result.errno = errno
                return result
            }
            guard ready > 0 else { continue }
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n == 0 {
                    return result
                } else if n > 0 {
                    result.bytes.append(contentsOf: buffer.prefix(n))
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    result.errno = errno
                    return result
                }
            }
        }
        return result
    }
}
