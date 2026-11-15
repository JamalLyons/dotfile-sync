import AgentRegistration
import Core
import Foundation
import IPC
import System
import Testing

@MainActor
struct RegistrationTests {
    @Test func registerMovesToRequiresApprovalAndExplains() {
        let registration = FakeRegistration(status: .notRegistered)
        let model = AppModel(registration: registration, agent: FakeAgent { _ throws(AgentCallError) in .pong })
        model.register()
        #expect(registration.calls == ["register"])
        #expect(model.registrationStatus == .requiresApproval)
        #expect(model.registrationMessage?.contains("Login Items") == true)
    }

    @Test func registerFailureIsShown() {
        let registration = FakeRegistration(status: .notRegistered, failRegister: true)
        let model = AppModel(registration: registration, agent: FakeAgent { _ throws(AgentCallError) in .pong })
        model.register()
        #expect(model.registrationMessage == "boom")
        #expect(model.registrationStatus == .notRegistered)
    }

    @Test func unregisterAndOpenLoginItems() {
        let registration = FakeRegistration(status: .enabled)
        let model = AppModel(registration: registration, agent: FakeAgent { _ throws(AgentCallError) in .pong })
        model.unregister()
        model.openLoginItems()
        #expect(registration.calls == ["unregister", "openLoginItems"])
        #expect(model.registrationStatus == .notRegistered)
        #expect(model.reachability == .unknown)
    }
}

@MainActor
struct AgentStatusTests {
    @Test func reachableAgentReportsVersion() async {
        let info = DaemonInfo(daemonVersion: "0.1.0", protocolVersion: 1, pid: 42, uptimeMs: 5, dataDir: "/fixture/data", activeJobs: 2, retainedJobs: 0)
        let agent = FakeAgent { _ throws(AgentCallError) in .daemonInfo(info) }
        let model = AppModel(registration: FakeRegistration(status: .enabled), agent: agent)
        await model.checkAgent()
        #expect(model.reachability == .reachable(version: "0.1.0", protocolVersion: 1, pid: 42, activeJobs: 2))
        #expect(agent.ops == ["daemon_info"])
    }

    @Test func unreachableAgentIsReported() async {
        let agent = FakeAgent { _ throws(AgentCallError) in throw .notRunning("lookup failed") }
        let model = AppModel(registration: FakeRegistration(status: .notRegistered), agent: agent)
        await model.checkAgent()
        guard case let .unreachable(reason) = model.reachability else {
            Issue.record("expected unreachable, got \(model.reachability)")
            return
        }
        #expect(reason.contains("lookup failed"))
    }
}

@MainActor
struct JobFlowTests {
    @Test func scanSummarizesReport() async {
        let report = ScanReport(
            homebrew: BrewDiscoveryResult(
                available: true, packagesEnumerated: true, brewVersion: "4.5.0",
                formulae: [ObservedPackage(name: "git", kind: .formula, installed: true)],
                casks: []
            ),
            configs: [
                ObservedConfigFile(sourcePath: "/r/a", targetPath: "/h/a", state: .matching),
                ObservedConfigFile(sourcePath: "/r/b", targetPath: "/h/b", state: .changed),
                ObservedConfigFile(sourcePath: "/r/c", targetPath: "/h/c", state: .changed),
            ],
            diagnostics: [.warning("heads up")]
        )
        let agent = FakeAgent { request throws(AgentCallError) in
            switch request {
            case .startJob: return .job(snapshot("j1", .running))
            case .jobResult: return .jobResult(.scan(report: report))
            default: throw .unexpected(request.opName)
            }
        }
        let model = AppModel(registration: FakeRegistration(status: .enabled), agent: agent, homePath: "/fixture/home")
        await model.runScan()
        #expect(model.phase == .idle)
        #expect(agent.ops == ["start_job", "watch_job", "job_result"])
        let scan = try! #require(model.scan)
        #expect(scan.formulae == 1)
        #expect(scan.configs == 3)
        #expect(scan.configStates == [StateCount(state: "changed", count: 2), StateCount(state: "matching", count: 1)])
        #expect(scan.diagnostics == ["warning: heads up"])
    }

    @Test func statusRequiresAbsoluteManifest() async {
        let agent = FakeAgent { _ throws(AgentCallError) in .pong }
        let model = AppModel(registration: FakeRegistration(status: .enabled), agent: agent, manifestPath: "relative.toml", homePath: "/fixture/home")
        await model.runStatus()
        #expect(agent.requests.isEmpty)
        guard case .failed = model.phase else {
            Issue.record("expected failure, got \(model.phase)")
            return
        }
    }

    @Test func failedJobIsReported() async {
        let agent = FakeAgent(terminal: snapshot("j1", .failed, error: JobError(code: .manifestLoad, message: "bad manifest"))) { request throws(AgentCallError) in
            .job(snapshot("j1", .running, kind: .status))
        }
        let model = AppModel(registration: FakeRegistration(status: .enabled), agent: agent, manifestPath: "/fixture/dotfilesync.toml", homePath: "/fixture/home")
        await model.runStatus()
        #expect(model.phase == .failed("Job j1 failed: bad manifest"))
        #expect(model.status == nil)
    }
}

@MainActor
struct ApplyFlowTests {
    /// Agent that creates a plan, approves it and applies it.
    private func planningAgent(actions: Int = 2) -> FakeAgent {
        let plan = samplePlan(actions: actions)
        return FakeAgent { request throws(AgentCallError) in
            switch request {
            case .planCreate: return .job(snapshot("plan-job", .running, kind: .plan))
            case let .jobResult(jobId) where jobId == "plan-job":
                return .jobResult(.plan(plan: plan, planId: "p-1"))
            case .planApprove: return .approval(ApprovalGrant(token: SECRET_TOKEN, expiresAtMs: 99))
            case .planApply: return .job(snapshot("apply-job", .running, kind: .apply))
            case let .jobResult(jobId) where jobId == "apply-job":
                return .jobResult(.apply(journal: RunJournal(runId: "r-1", planDigest: plan.digest, steps: [
                    StepRecord(actionId: "a-001", status: .running, atMs: 1),
                    StepRecord(actionId: "a-001", status: .done, atMs: 2),
                    StepRecord(actionId: "a-002", status: .failed, error: "nope", atMs: 3),
                ])))
            default: throw .unexpected(request.opName)
            }
        }
    }

    private func model(_ agent: FakeAgent) -> AppModel {
        AppModel(registration: FakeRegistration(status: .enabled), agent: agent, manifestPath: "/fixture/dotfilesync.toml", homePath: "/fixture/home")
    }

    @Test func planIsSummarizedWithDigest() async {
        let agent = planningAgent()
        let model = model(agent)
        await model.runPlan()
        let plan = try! #require(model.plan)
        #expect(plan.planId == "p-1")
        #expect(plan.digest == samplePlan(actions: 2).digest)
        #expect(plan.actions.count == 2)
        #expect(plan.highRiskCount == 1)
        #expect(model.canApply)
    }

    @Test func presenceRefusedByTheAgentIsReportedAsCancelled() async {
        let plan = samplePlan(actions: 1)
        let refusal = ProtocolError(.approvalRejected, "user presence was not confirmed: user cancelled")
            .withDetails(.object([("reason", .string("user_presence"))]))
        let agent = FakeAgent { request throws(AgentCallError) in
            switch request {
            case .planCreate: return .job(snapshot("plan-job", .running, kind: .plan))
            case .jobResult: return .jobResult(.plan(plan: plan, planId: "p-1"))
            case .planApprove: throw .remote(refusal)
            default: throw .unexpected(request.opName)
            }
        }
        let model = model(agent)
        await model.runPlan()
        await model.applyPlan()
        #expect(!agent.ops.contains("plan.apply"))
        #expect(model.apply == .cancelled("Not applied: user presence was not confirmed: user cancelled."))
        #expect(model.plan != nil)
    }

    @Test func approvesThenAppliesAndHidesToken() async {
        let agent = planningAgent()
        let model = model(agent)
        await model.runPlan()
        await model.applyPlan()

        let ops = agent.ops
        let approve = try! #require(ops.firstIndex(of: "plan.approve"))
        let apply = try! #require(ops.firstIndex(of: "plan.apply"))
        #expect(approve < apply)
        #expect(agent.requests.contains(.planApprove(planId: "p-1", digest: samplePlan(actions: 2).digest)))
        #expect(agent.requests.contains(.planApply(planId: "p-1", token: SECRET_TOKEN, allowSudo: false)))

        guard case let .completed(summary) = model.apply else {
            Issue.record("expected completion, got \(model.apply)")
            return
        }
        #expect(summary.runId == "r-1")
        #expect(summary.done == 1)
        #expect(summary.failed == 1)
        #expect(summary.errors == ["a-002: nope"])
        #expect(model.plan == nil, "an applied plan must be re-planned before another apply")

        // The token must not survive anywhere the UI can render or log it.
        let visible = "\(model.apply) \(String(describing: model.plan)) \(model.progress) \(model.phase)"
        #expect(!visible.contains(SECRET_TOKEN))
        #expect(!"\(ApprovalGrant(token: SECRET_TOKEN, expiresAtMs: 1))".contains(SECRET_TOKEN))
    }

    @Test func emptyPlanCannotBeApplied() async {
        let agent = planningAgent(actions: 0)
        let model = model(agent)
        await model.runPlan()
        #expect(model.plan?.isEmpty == true)
        #expect(!model.canApply)
        await model.applyPlan()
        #expect(!agent.ops.contains("plan.approve"))
    }

    @Test func approvalRejectionIsReported() async {
        let plan = samplePlan(actions: 1)
        let agent = FakeAgent { request throws(AgentCallError) in
            switch request {
            case .planCreate: return .job(snapshot("plan-job", .running, kind: .plan))
            case .jobResult: return .jobResult(.plan(plan: plan, planId: "p-1"))
            case .planApprove: throw .remote(ProtocolError(.approvalRejected, "stale plan"))
            default: throw .unexpected(request.opName)
            }
        }
        let model = model(agent)
        await model.runPlan()
        await model.applyPlan()
        #expect(!agent.ops.contains("plan.apply"))
        guard case let .failed(message) = model.apply else {
            Issue.record("expected failure, got \(model.apply)")
            return
        }
        #expect(message.contains("stale plan"))
    }
}
