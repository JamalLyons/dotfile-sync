// State and actions behind the SwiftUI shell. All side effects go through injected protocols
// (`AgentRegistering`, `AgentClient`) so tests drive it with fakes.

import AgentRegistration
import Core
import Foundation
import IPC
import Observation
import System

/// Whether the agent answered a `daemon_info` request.
enum AgentReachability: Equatable, Sendable {
    case unknown
    case checking
    case reachable(version: String, protocolVersion: UInt32, pid: UInt32, activeJobs: Int)
    case unreachable(String)
}

/// Progress of a scan/status/plan/apply operation.
enum Phase: Equatable, Sendable {
    case idle
    case running(String)
    case failed(String)
}

/// Where the apply flow stands. The approval token never appears here.
enum ApplyState: Equatable, Sendable {
    case idle
    /// Waiting for the agent, which asks for Touch ID or the password before it approves.
    case approving
    case applying(jobId: String)
    case completed(ApplySummary)
    case cancelled(String)
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    // Inputs
    var manifestPath: String
    var homePath: String
    var profile: String = ""

    // Registration and reachability
    private(set) var registrationStatus: AgentRegistrationStatus
    private(set) var registrationMessage: String?
    private(set) var reachability: AgentReachability = .unknown

    // Results
    private(set) var phase: Phase = .idle
    private(set) var progress: [String] = []
    private(set) var scan: ScanSummary?
    private(set) var status: StatusOverview?
    private(set) var plan: PlanSummary?
    private(set) var apply: ApplyState = .idle

    @ObservationIgnored private let registration: any AgentRegistering
    @ObservationIgnored private let agent: any AgentClient

    init(
        registration: any AgentRegistering,
        agent: any AgentClient,
        manifestPath: String = "",
        homePath: String = NSHomeDirectory()
    ) {
        self.registration = registration
        self.agent = agent
        self.manifestPath = manifestPath
        self.homePath = homePath
        registrationStatus = registration.status
    }

    var isBusy: Bool {
        if case .running = phase { return true }
        switch apply {
        case .approving, .applying: return true
        default: return false
        }
    }

    /// Apply is offered only for a non-empty plan and while nothing else runs.
    var canApply: Bool {
        guard let plan, !plan.isEmpty else { return false }
        return !isBusy
    }

    // MARK: - Registration

    func refreshRegistration() {
        registrationStatus = registration.status
    }

    func register() {
        do {
            let outcome = try registration.register()
            registrationMessage = outcome == .registered ? "Registered the agent." : "The agent was already registered."
        } catch {
            registrationMessage = error.message
        }
        refreshRegistration()
        if registrationStatus == .requiresApproval {
            registrationMessage = "Allow dotfilesync in System Settings → General → Login Items."
        }
    }

    func unregister() {
        do {
            let outcome = try registration.unregister()
            registrationMessage = outcome == .unregistered ? "Unregistered the agent." : "The agent was not registered."
        } catch {
            registrationMessage = error.message
        }
        refreshRegistration()
        reachability = .unknown
    }

    func openLoginItems() {
        registration.openSystemSettingsLoginItems()
    }

    // MARK: - Agent

    func checkAgent() async {
        reachability = .checking
        do {
            let response = try await agent.call(.daemonInfo)
            guard case let .daemonInfo(info) = response else {
                reachability = .unreachable("unexpected reply \(response.kindName)")
                return
            }
            reachability = .reachable(
                version: info.daemonVersion,
                protocolVersion: info.protocolVersion,
                pid: info.pid,
                activeJobs: info.activeJobs
            )
        } catch {
            reachability = .unreachable(error.description)
        }
    }

    func runScan() async {
        guard let home = requireHome() else { return }
        let manifest = manifestPath.isEmpty ? nil : FilePath(manifestPath)
        guard let output = await runJob("Scanning", .startJob(spec: .scan(ScanInput(manifest: manifest, home: home, profile: profileOrNil)))) else { return }
        guard case let .scan(report) = output else { return unexpected(output) }
        scan = ScanSummary(report)
    }

    func runStatus() async {
        guard let home = requireHome(), let manifest = requireManifest() else { return }
        guard let output = await runJob("Checking status", .startJob(spec: .status(StatusInput(manifest: manifest, home: home, profile: profileOrNil)))) else { return }
        guard case let .status(report) = output else { return unexpected(output) }
        status = StatusOverview(report)
    }

    func runPlan() async {
        guard let home = requireHome(), let manifest = requireManifest() else { return }
        plan = nil
        apply = .idle
        guard let output = await runJob("Planning", .planCreate(input: PlanInput(manifest: manifest, home: home, profile: profileOrNil))) else { return }
        guard case let .plan(created, planId) = output else { return unexpected(output) }
        plan = PlanSummary(plan: created, planId: planId)
    }

    /// Requests a one-time approval for the reviewed plan and applies it. The agent asks for
    /// Touch ID or the password before it issues the approval, for this app and the CLI alike.
    func applyPlan() async {
        guard canApply, let plan else { return }
        apply = .approving
        let job: JobSnapshot
        do {
            // The token lives only in this scope: it is never stored, logged or displayed.
            let approval = try await agent.call(.planApprove(planId: plan.planId, digest: plan.digest))
            guard case let .approval(grant) = approval else {
                apply = .failed("Unexpected reply \(approval.kindName) to the approval request.")
                return
            }
            let started = try await agent.call(.planApply(planId: plan.planId, token: grant.token, allowSudo: false))
            guard case let .job(snapshot) = started else {
                apply = .failed("Unexpected reply \(started.kindName) to the apply request.")
                return
            }
            job = snapshot
        } catch {
            if case let .remote(remote) = error, remote.reason == "user_presence" {
                apply = .cancelled("Not applied: \(remote.message).")
            } else {
                apply = .failed(error.description)
            }
            return
        }

        apply = .applying(jobId: job.jobId)
        progress = []
        do {
            let output = try await finish(job)
            guard case let .apply(journal) = output else {
                apply = .failed("Unexpected result for job \(job.jobId).")
                return
            }
            apply = .completed(ApplySummary(journal))
            // The applied plan is spent; a new one must be created and reviewed.
            self.plan = nil
        } catch let failure as JobFailure {
            apply = .failed(failure.message)
        } catch {
            apply = .failed("\(error)")
        }
    }

    // MARK: - Helpers

    private var profileOrNil: String? {
        let trimmed = profile.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func requireHome() -> FilePath? {
        let path = FilePath(homePath)
        guard path.isAbsolute else {
            phase = .failed("The home directory must be an absolute path.")
            return nil
        }
        return path
    }

    private func requireManifest() -> FilePath? {
        let path = FilePath(manifestPath)
        guard !manifestPath.isEmpty, path.isAbsolute else {
            phase = .failed("Choose the manifest (an absolute path to dotfilesync.toml).")
            return nil
        }
        return path
    }

    private func unexpected(_ output: JobOutput) {
        phase = .failed("The agent returned an unexpected result kind.")
    }

    /// Starts a job, follows it, and returns its output (or records the failure).
    private func runJob(_ label: String, _ request: Request) async -> JobOutput? {
        phase = .running(label)
        progress = []
        do {
            let response = try await agent.call(request)
            guard case let .job(job) = response else {
                phase = .failed("Unexpected reply \(response.kindName).")
                return nil
            }
            let output = try await finish(job)
            phase = .idle
            return output
        } catch let failure as JobFailure {
            phase = .failed(failure.message)
        } catch let error as AgentCallError {
            phase = .failed(error.description)
        } catch {
            phase = .failed("\(error)")
        }
        return nil
    }

    private struct JobFailure: Error {
        var message: String
    }

    private func finish(_ job: JobSnapshot) async throws -> JobOutput {
        var final = job
        if !job.status.isTerminal {
            final = try await agent.waitForJob(job.jobId) { [weak self] event in
                let line = "[\(event.stage)] \(event.message)"
                Task { @MainActor in self?.progress.append(line) }
            }
        }
        guard final.status == .succeeded else {
            throw JobFailure(message: "Job \(final.jobId) \(final.status): \(final.error?.message ?? "no details")")
        }
        let response = try await agent.call(.jobResult(jobId: final.jobId))
        guard case let .jobResult(output) = response else {
            throw JobFailure(message: "Unexpected reply \(response.kindName) for the job result.")
        }
        return output
    }
}
