// The app's view of the agent: typed requests over XPC, run off the main thread.

import Dispatch
import Foundation
import IPC
import Synchronization
import XPCTransport

/// Why an agent call failed.
enum AgentCallError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No agent answered (not registered, not approved in Login Items, or data dir missing).
    case notRunning(String)
    /// The transport failed after connecting, or the data directory is unsafe.
    case transport(String)
    /// The agent answered with a typed error.
    case remote(ProtocolError)
    /// The agent answered with something this app does not expect.
    case unexpected(String)

    var description: String {
        switch self {
        case let .notRunning(reason): return "The agent is not running (\(reason))."
        case let .transport(reason): return reason
        case let .remote(error): return "The agent refused the request: \(error.message) (\(error.code.rawValue))."
        case let .unexpected(what): return "Unexpected reply from the agent: \(what)."
        }
    }
}

/// Requests the app sends to the agent. ``LiveAgentClient`` in the app, a fake in tests.
protocol AgentClient: Sendable {
    /// Sends one request and returns the successful response.
    func call(_ request: Request) async throws(AgentCallError) -> Response
    /// Follows `jobId` until it is terminal, reporting progress, and returns the final snapshot.
    func waitForJob(
        _ jobId: String,
        onProgress: @escaping @Sendable (ProgressEvent) -> Void
    ) async throws(AgentCallError) -> JobSnapshot
}

/// ``AgentClient`` over the agent's launchd Mach service.
///
/// `AgentXPCClient` blocks its calling thread, so every call runs on a global queue. The
/// connection is created lazily and dropped after a transport failure so the next call
/// reconnects (e.g. after the user approves the agent in Login Items).
final class LiveAgentClient: AgentClient {
    private let machService: String
    private let connection = Mutex<AgentXPCClient?>(nil)

    init(machService: String = AGENT_MACH_SERVICE) {
        self.machService = machService
    }

    func call(_ request: Request) async throws(AgentCallError) -> Response {
        try await offMain { () throws(AgentCallError) -> Response in
            let client = try self.client()
            let outcome: Outcome
            do throws(AgentXPCClientError) {
                outcome = try client.send(request)
            } catch {
                self.drop()
                throw Self.map(error)
            }
            switch outcome {
            case let .ok(response): return response
            case let .err(error): throw .remote(error)
            }
        }
    }

    func waitForJob(
        _ jobId: String,
        onProgress: @escaping @Sendable (ProgressEvent) -> Void
    ) async throws(AgentCallError) -> JobSnapshot {
        try await offMain { () throws(AgentCallError) -> JobSnapshot in
            let client = try self.client()
            let outcome: Outcome?
            do throws(AgentXPCClientError) {
                outcome = try client.watch(jobId: jobId) { notification in
                    if case let .progress(_, event) = notification {
                        onProgress(event)
                    }
                    return true
                }
            } catch {
                self.drop()
                throw Self.map(error)
            }
            switch outcome {
            case let .ok(.job(snapshot))?: return snapshot
            case let .ok(other)?: throw .unexpected("\(other.kindName) while watching job \(jobId)")
            case let .err(error)?: throw .remote(error)
            case nil: throw .unexpected("the watch of job \(jobId) ended early")
            }
        }
    }

    private func client() throws(AgentCallError) -> AgentXPCClient {
        if let existing = connection.withLock({ $0 }) {
            return existing
        }
        let layout: DataLayout
        do {
            layout = try DataLayout.resolve()
        } catch {
            throw .transport(error.description)
        }
        let created: AgentXPCClient
        do {
            created = try AgentXPCClient(machService: machService, layout: layout, policy: .live())
        } catch {
            throw Self.map(error)
        }
        connection.withLock { $0 = created }
        return created
    }

    private func drop() {
        let old = connection.withLock { current -> AgentXPCClient? in
            defer { current = nil }
            return current
        }
        old?.close()
    }

    private static func map(_ error: AgentXPCClientError) -> AgentCallError {
        if case let .notRunning(reason) = error {
            return .notRunning(reason)
        }
        return .transport(error.description)
    }
}

/// Runs blocking `work` on a global queue and resumes with its result.
private func offMain<T: Sendable>(
    _ work: @escaping @Sendable () throws(AgentCallError) -> T
) async throws(AgentCallError) -> T {
    let result: Result<T, AgentCallError> = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do throws(AgentCallError) {
                continuation.resume(returning: .success(try work()))
            } catch {
                continuation.resume(returning: .failure(error))
            }
        }
    }
    return try result.get()
}

extension Response {
    /// Short, token-free name of the response variant for error messages.
    var kindName: String {
        switch self {
        case .pong: return "pong"
        case .daemonInfo: return "daemon_info"
        case .job: return "job"
        case .jobs: return "jobs"
        case .progress: return "progress"
        case .jobResult: return "job_result"
        case .shuttingDown: return "shutting_down"
        case .approval: return "approval"
        case .runs: return "runs"
        case .run: return "run"
        }
    }
}
