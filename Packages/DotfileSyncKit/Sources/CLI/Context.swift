// Process-level dependencies of the CLI, injectable so tests run commands in-process.

import AgentRegistration
import Darwin
import Foundation
import IPC
import Synchronization
import XPCTransport

/// Everything a command reads from or writes to the outside world.
///
/// ``live()`` wires the real process: stdout/stderr, the environment, the current directory,
/// the agent's launchd Mach service and the real `SMAppService` registration. Tests replace
/// `connectAgent` with an anonymous XPC endpoint and `registration` with a fake, so they never
/// contact launchd. Neither seam is reachable from the command line.
public struct CLIContext: Sendable {
    /// Writes to standard output (no newline added).
    public var stdout: @Sendable (String) -> Void
    /// Writes to standard error (no newline added).
    public var stderr: @Sendable (String) -> Void
    /// Environment used for `HOME`, `DOTFILESYNC_DATA_DIR` and `DOTFILESYNC_BREW_BIN`.
    public var environment: [String: String]
    /// Directory that relative paths are made absolute against before they go to the agent.
    public var currentDirectory: String
    /// Whether standard input is a terminal (`apply` only prompts on a TTY).
    public var stdinIsTerminal: Bool
    /// Reads one line from standard input for confirmation prompts; `nil` at end of input.
    public var readLine: @Sendable () -> String?
    /// Opens a connection to the agent for `layout`.
    public var connectAgent: @Sendable (DataLayout) throws(AgentXPCClientError) -> AgentXPCClient
    /// Returns the agent registration; only called by `service` commands.
    public var registration: @Sendable () -> any AgentRegistering

    /// Creates a context from explicit parts.
    public init(
        stdout: @escaping @Sendable (String) -> Void,
        stderr: @escaping @Sendable (String) -> Void,
        environment: [String: String],
        currentDirectory: String,
        stdinIsTerminal: Bool,
        readLine: @escaping @Sendable () -> String?,
        connectAgent: @escaping @Sendable (DataLayout) throws(AgentXPCClientError) -> AgentXPCClient,
        registration: @escaping @Sendable () -> any AgentRegistering
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.stdinIsTerminal = stdinIsTerminal
        self.readLine = readLine
        self.connectAgent = connectAgent
        self.registration = registration
    }

    /// The real process: Mach service `AGENT_MACH_SERVICE` and `SMAppService`.
    public static func live() -> CLIContext {
        CLIContext(
            stdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
            stderr: { FileHandle.standardError.write(Data($0.utf8)) },
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: FileManager.default.currentDirectoryPath,
            stdinIsTerminal: isatty(STDIN_FILENO) == 1,
            readLine: { Swift.readLine(strippingNewline: true) },
            connectAgent: { layout throws(AgentXPCClientError) in
                try AgentXPCClient(machService: AGENT_MACH_SERVICE, layout: layout)
            },
            registration: { AgentRegistration() }
        )
    }

    func out(_ line: String) { stdout(line + "\n") }
    func err(_ line: String) { stderr(line + "\n") }
}

/// A command failure, printed like anyhow: `Error: <message>` then an optional cause chain.
public struct CLIError: Error, Sendable, CustomStringConvertible {
    public var message: String
    /// Underlying causes, outermost first (anyhow's `Caused by:` list).
    public var causes: [String]

    public init(_ message: String, causes: [String] = []) {
        self.message = message
        self.causes = causes
    }

    public var description: String { message }

    /// The text written to stderr (anyhow's `{:?}` format).
    var rendered: String {
        var s = "Error: \(message)\n"
        if causes.count == 1 {
            s += "\nCaused by:\n    \(indented(causes[0], by: 4))\n"
        } else if causes.count > 1 {
            s += "\nCaused by:\n"
            for (i, cause) in causes.enumerated() {
                let prefix = "    \(i): "
                s += prefix + indented(cause, by: prefix.count) + "\n"
            }
        }
        return s
    }

    /// anyhow indents continuation lines of a multi-line cause under its first line.
    private func indented(_ text: String, by width: Int) -> String {
        let pad = String(repeating: " ", count: width)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { $0.offset == 0 ? String($0.element) : pad + $0.element }
            .joined(separator: "\n")
    }
}
