import Foundation
import Synchronization
import System

/// Captured result of a subprocess that exited successfully (exit code 0).
public struct CommandOutput: Sendable, Equatable {
    public var statusCode: Int32
    public var stdout: String
    public var stderr: String

    public init(statusCode: Int32, stdout: String, stderr: String) {
        self.statusCode = statusCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Failure modes of a ``CommandRunner`` invocation.
///
/// ``description`` matches the Rust `Display` strings exactly.
public enum RunnerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The executable could not be found (spawn returned `ENOENT`).
    case executableNotFound(String)
    /// The process could not be spawned or waited on.
    case executionFailed(program: String, message: String)
    /// The overall call deadline elapsed; owned processes were killed.
    case timeout(program: String, timeout: Duration)
    /// The attached ``CancellationFlag`` was set; owned processes were killed.
    case cancelled(program: String)
    /// The process exited unsuccessfully (non-zero code, or killed by a signal with code `-1`).
    case nonZeroExit(program: String, code: Int32, stderr: String)

    public var description: String {
        switch self {
        case .executableNotFound(let program):
            return "Executable '\(program)' was not found"
        case .executionFailed(let program, let message):
            return "Command '\(program)' failed to execute: \(message)"
        case .timeout(let program, let timeout):
            return "Command '\(program)' timed out after \(formatTimeout(timeout))"
        case .cancelled(let program):
            return "Command '\(program)' was cancelled"
        case .nonZeroExit(let program, let code, let stderr):
            return "Command '\(program)' exited with code \(code): \(stderr)"
        }
    }
}

/// Formats a timeout like the Rust runner: `"400ms"` below one second, `"30s"` for whole
/// seconds, otherwise seconds with two decimals (`"1.50s"`).
public func formatTimeout(_ timeout: Duration) -> String {
    let (seconds, attoseconds) = timeout.components
    let subsecMillis = attoseconds / 1_000_000_000_000_000
    let millis = seconds * 1000 + subsecMillis
    if millis < 1000 {
        return "\(millis)ms"
    } else if subsecMillis == 0 {
        return "\(seconds)s"
    } else {
        let secondsF64 = Double(seconds) + Double(attoseconds) / 1e18
        return String(format: "%.2fs", secondsF64)
    }
}

/// Executes external programs. Synchronous, like the Rust `CommandRunner` trait.
public protocol CommandRunner: Sendable {
    /// Runs `program` (a name looked up via ``findExecutable(_:)``, or a path) with `args`.
    func run(_ program: String, args: [String]) throws(RunnerError) -> CommandOutput

    /// Runs `program` given as a native path, which may contain non-UTF-8 bytes.
    func runPath(_ program: FilePath, args: [String]) throws(RunnerError) -> CommandOutput

    /// Resolves an executable name to a path, or `nil` when it cannot be located.
    func findExecutable(_ name: String) -> FilePath?
}

extension CommandRunner {
    public func run(_ program: String, args: [String]) throws(RunnerError) -> CommandOutput {
        try runPath(FilePath(program), args: args)
    }
}

/// Shared, thread-safe cancellation flag (Rust: `Arc<AtomicBool>`).
public final class CancellationFlag: Sendable {
    private let state = Atomic<Bool>(false)

    public init() {}

    /// Sets the flag; a running ``RealCommandRunner`` call will kill its processes and throw
    /// ``RunnerError/cancelled(program:)``.
    public func cancel() {
        state.store(true, ordering: .sequentiallyConsistent)
    }

    /// Stores an explicit value (mirrors `AtomicBool::store`).
    public func set(_ value: Bool) {
        state.store(value, ordering: .sequentiallyConsistent)
    }

    public var isCancelled: Bool {
        state.load(ordering: .sequentiallyConsistent)
    }
}

/// Canned-response runner for tests and offline discovery.
///
/// Unknown commands throw ``RunnerError/executableNotFound(_:)``; unknown executables resolve
/// to `nil`.
public struct MockCommandRunner: CommandRunner {
    private struct CommandKey: Hashable, Sendable {
        var program: String
        var args: [String]
    }

    private var executables: [String: FilePath?] = [:]
    private var cannedResponses: [CommandKey: Result<CommandOutput, RunnerError>] = [:]

    public init() {}

    /// Registers how ``findExecutable(_:)`` resolves `name` (`nil` means not found).
    public func withExecutable(_ name: String, _ path: FilePath?) -> MockCommandRunner {
        var copy = self
        copy.executables[name] = .some(path)
        return copy
    }

    /// Registers the response for an exact `program` + `args` invocation.
    public func withResponse(
        _ program: String,
        args: [String],
        _ response: Result<CommandOutput, RunnerError>
    ) -> MockCommandRunner {
        var copy = self
        copy.cannedResponses[CommandKey(program: program, args: args)] = response
        return copy
    }

    public func findExecutable(_ name: String) -> FilePath? {
        executables[name] ?? nil
    }

    public func run(_ program: String, args: [String]) throws(RunnerError) -> CommandOutput {
        guard let response = cannedResponses[CommandKey(program: program, args: args)] else {
            throw .executableNotFound(program)
        }
        return try response.get()
    }

    public func runPath(_ program: FilePath, args: [String]) throws(RunnerError) -> CommandOutput {
        guard let response = cannedResponses[CommandKey(program: program.string, args: args)] else {
            throw .executableNotFound(program.string)
        }
        return try response.get()
    }
}
