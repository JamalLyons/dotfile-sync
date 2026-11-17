// Ports of the inline tests in crates/dotfilesync-protocol/src/messages.rs, plus JSON parity
// pins. Expected strings were generated from the Rust types with serde_json::to_string.

import Core
import Foundation
import IPC
import System
import Testing

private func compact<T: Encodable>(_ value: T) throws -> String {
    try jsonStringCompact(value)
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(try compact(value).utf8))
}

private func params(_ request: Request) throws -> Data {
    guard case let .object(members) = try jsonValue(request),
          let params = members.first(where: { $0.0 == "params" })?.1
    else {
        Issue.record("request has no params")
        return Data()
    }
    return Data(try jsonStringCompact(AnyJSON(params)).utf8)
}

private let job = JobSnapshot(
    jobId: "j-1", kind: .scan, status: .running, createdAtMs: 1, finishedAtMs: nil,
    latestSeq: 2, cancelRequested: false, fromPreviousRun: false, error: nil
)
private let event = ProgressEvent(seq: 1, atMs: 0, stage: "s", message: "m")
private let emptyScan = ScanReport(homebrew: BrewDiscoveryResult(), configs: [], diagnostics: [])

@Suite struct MessageTests {
    // messages.rs: request_round_trips_through_envelope
    @Test func requestRoundTripsThroughEnvelope() throws {
        let req = Request.startJob(spec: .status(StatusInput(
            manifest: FilePath("/tmp/m.toml"), home: FilePath("/tmp/home"), repoRoot: nil, profile: nil
        )))
        let json = try compact(req)
        #expect(json.contains("\"op\":\"start_job\""))
        #expect(try Request.decode(op: req.opName, params: try params(req)) == req)
        #expect(try Request.decode(json: Data(json.utf8)) == req)

        let planReq = Request.planCreate(input: PlanInput(
            manifest: FilePath("/tmp/m.toml"), home: FilePath("/tmp/home"), repoRoot: nil, profile: "work"
        ))
        #expect(planReq.opName == "plan.create")
        #expect(try Request.decode(json: Data(try compact(planReq).utf8)) == planReq)
    }

    // messages.rs: unit_like_requests_accept_missing_params
    @Test func unitLikeRequestsAcceptMissingParams() throws {
        #expect(try Request.decode(op: "ping", params: nil) == .ping)
        #expect(try Request.decode(json: Data(#"{"op":"ping"}"#.utf8)) == .ping)
        #expect(try Request.decode(json: Data(#"{"op":"plan.runs","params":null}"#.utf8)) == .planRuns)
    }

    // messages.rs: reserved_unknown_and_invalid_are_distinguished
    @Test func reservedUnknownAndInvalidAreDistinguished() {
        func code(_ op: String, _ params: String?) -> ErrorCode? {
            do {
                _ = try Request.decode(op: op, params: params.map { Data($0.utf8) })
                return nil
            } catch {
                return error.code
            }
        }
        #expect(code("runtime.x", nil) == .unsupportedOperation)
        #expect(code("sync.push", nil) == .unsupportedOperation)
        #expect(code("exec", nil) == .unknownOperation)
        #expect(code("job_status", #"{"job_id":5}"#) == .invalidParams)
    }

    // messages.rs: job_spec_has_no_command_field
    @Test func jobSpecHasNoCommandField() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(JobSpec.self, from: Data(#"{"kind":"shell","command":"rm -rf ~"}"#.utf8))
        }
    }

    // messages.rs: every_response_variant_round_trips_inside_a_server_frame
    // (ServerFrame is not ported; each Outcome round-trips instead.)
    @Test func everyResponseVariantRoundTrips() throws {
        let responses: [Response] = [
            .pong,
            .job(job),
            .jobs([job]),
            .progress(job: job, events: [], truncated: false),
            .jobResult(.scan(report: emptyScan)),
            .shuttingDown,
            .approval(ApprovalGrant(token: "secret", expiresAtMs: 10)),
            .runs([]),
            .run(RunView(runId: "r-1", planDigest: "d", steps: [], status: .interrupted, planId: "p-1", jobId: "j-1")),
        ]
        for r in responses {
            let outcome = Outcome.ok(r)
            let json = try compact(outcome)
            #expect(try roundTrip(outcome) == outcome, "\(json)")
        }
        let n = Notification.progress(jobId: "j", event: event)
        #expect(try roundTrip(n) == n)
    }

    // messages.rs: unknown_error_codes_from_newer_daemons_decode
    @Test func unknownErrorCodesFromNewerDaemonsDecode() throws {
        let e = try JSONDecoder().decode(ProtocolError.self, from: Data(#"{"code":"brand_new","message":"x"}"#.utf8))
        #expect(e.code == .unknown)
    }

    @Test func implementedOpsMatchRequestNames() throws {
        let all: [Request] = [
            .ping, .daemonInfo, .startJob(spec: .scan(ScanInput(manifest: nil, home: FilePath("/h")))),
            .jobStatus(jobId: "j"), .listJobs, .jobProgress(jobId: "j", sinceSeq: 0),
            .watchJob(jobId: "j", sinceSeq: 0), .jobResult(jobId: "j"), .cancelJob(jobId: "j"), .shutdown,
            .planCreate(input: PlanInput(manifest: FilePath("/m"), home: FilePath("/h"))),
            .planApprove(planId: "p", digest: "d"), .planApply(planId: "p", token: "t", allowSudo: false),
            .planResume(runId: "r", token: "t", allowSudo: false), .planRuns, .planRunStatus(runId: "r"),
        ]
        #expect(all.map(\.opName) == IMPLEMENTED_OPS)
        for r in all {
            #expect(try Request.decode(json: Data(try compact(r).utf8)) == r)
        }
    }

    @Test func allowSudoDefaultsToFalse() throws {
        #expect(try Request.decode(op: "plan.apply", params: Data(#"{"plan_id":"p","token":"t"}"#.utf8))
            == .planApply(planId: "p", token: "t", allowSudo: false))
        #expect(try Request.decode(op: "plan.resume", params: Data(#"{"run_id":"r","token":"t"}"#.utf8))
            == .planResume(runId: "r", token: "t", allowSudo: false))
    }

    @Test func approvalGrantDescriptionHidesToken() {
        let grant = ApprovalGrant(token: "supersecret", expiresAtMs: 1)
        #expect(!"\(grant)".contains("supersecret"))
        #expect(!String(reflecting: grant).contains("supersecret"))
    }
}

/// F4: JSON parity. Each string is exactly what serde_json produced for the same Rust value.
@Suite struct JSONParityTests {
    @Test(arguments: [
        (Request.ping, #"{"op":"ping","params":{}}"#),
        (.daemonInfo, #"{"op":"daemon_info","params":{}}"#),
        (.startJob(spec: .scan(ScanInput(manifest: nil, home: FilePath("/h")))),
         #"{"op":"start_job","params":{"spec":{"kind":"scan","manifest":null,"home":"/h","repo_root":null}}}"#),
        (.startJob(spec: .status(StatusInput(manifest: FilePath("/m.toml"), home: FilePath("/h"), repoRoot: FilePath("/r"), profile: "work"))),
         #"{"op":"start_job","params":{"spec":{"kind":"status","manifest":"/m.toml","home":"/h","repo_root":"/r","profile":"work"}}}"#),
        (.jobStatus(jobId: "j-1"), #"{"op":"job_status","params":{"job_id":"j-1"}}"#),
        (.listJobs, #"{"op":"list_jobs","params":{}}"#),
        (.jobProgress(jobId: "j-1", sinceSeq: 3), #"{"op":"job_progress","params":{"job_id":"j-1","since_seq":3}}"#),
        (.watchJob(jobId: "j-1", sinceSeq: 0), #"{"op":"watch_job","params":{"job_id":"j-1","since_seq":0}}"#),
        (.jobResult(jobId: "j-1"), #"{"op":"job_result","params":{"job_id":"j-1"}}"#),
        (.cancelJob(jobId: "j-1"), #"{"op":"cancel_job","params":{"job_id":"j-1"}}"#),
        (.shutdown, #"{"op":"shutdown","params":{}}"#),
        (.planCreate(input: PlanInput(manifest: FilePath("/m.toml"), home: FilePath("/h"))),
         #"{"op":"plan.create","params":{"input":{"manifest":"/m.toml","home":"/h","repo_root":null}}}"#),
        (.planApprove(planId: "p-1", digest: "d"), #"{"op":"plan.approve","params":{"plan_id":"p-1","digest":"d"}}"#),
        (.planApply(planId: "p-1", token: "t", allowSudo: true),
         #"{"op":"plan.apply","params":{"plan_id":"p-1","token":"t","allow_sudo":true}}"#),
        (.planResume(runId: "r-1", token: "t", allowSudo: false),
         #"{"op":"plan.resume","params":{"run_id":"r-1","token":"t","allow_sudo":false}}"#),
        (.planRuns, #"{"op":"plan.runs","params":{}}"#),
        (.planRunStatus(runId: "r-1"), #"{"op":"plan.run_status","params":{"run_id":"r-1"}}"#),
    ])
    func request(_ request: Request, _ expected: String) throws {
        #expect(try compact(request) == expected)
        #expect(try Request.decode(json: Data(expected.utf8)) == request)
    }

    @Test(arguments: responseCases)
    func response(_ response: Response, _ expected: String) throws {
        #expect(try compact(response) == expected)
        #expect(try JSONDecoder().decode(Response.self, from: Data(expected.utf8)) == response)
    }

    @Test func outcomesErrorsAndNotifications() throws {
        #expect(try compact(Outcome.ok(.pong)) == #"{"ok":{"response":"pong"}}"#)
        let rejected = ProtocolError(.approvalRejected, "x").withDetails(.object([("reason", .string("plan_mismatch"))]))
        let errJSON = #"{"err":{"code":"approval_rejected","message":"x","details":{"reason":"plan_mismatch"}}}"#
        #expect(try compact(Outcome.err(rejected)) == errJSON)
        let back = try JSONDecoder().decode(Outcome.self, from: Data(errJSON.utf8))
        #expect(back == .err(rejected))
        if case let .err(e) = back { #expect(e.reason == "plan_mismatch") }
        #expect(try compact(ProtocolError(.jobNotFound, "no")) == #"{"code":"job_not_found","message":"no"}"#)
        #expect(try compact(Notification.progress(jobId: "j", event: event))
            == #"{"kind":"progress","job_id":"j","event":{"seq":1,"at_ms":0,"stage":"s","message":"m"}}"#)
        #expect(try compact(Notification.heartbeat) == #"{"kind":"heartbeat"}"#)
    }

    @Test func everyErrorCodeEncodesSnakeCase() throws {
        let expected = [
            "incompatible_version", "unauthorized", "malformed_request", "frame_too_large",
            "handshake_required", "unknown_operation", "unsupported_operation", "invalid_params",
            "job_not_found", "job_not_finished", "job_failed", "busy", "shutting_down", "internal",
            "plan_not_found", "approval_rejected", "unknown",
        ]
        #expect(ErrorCode.allCases.map(\.rawValue) == expected)
    }
}

private let failedApply = JobSnapshot(
    jobId: "j-1", kind: .apply, status: .failed, createdAtMs: 1, finishedAtMs: 5, latestSeq: 2,
    cancelRequested: false, fromPreviousRun: false, error: JobError(code: .manifestLoad, message: "m")
)

private let responseCases: [(Response, String)] = [
    (.pong, #"{"response":"pong"}"#),
    (.daemonInfo(DaemonInfo(daemonVersion: "0.1.0", protocolVersion: 1, pid: 42, uptimeMs: 7, dataDir: FilePath("/d"), activeJobs: 1, retainedJobs: 2)),
     #"{"response":"daemon_info","daemon_version":"0.1.0","protocol_version":1,"pid":42,"uptime_ms":7,"data_dir":"/d","active_jobs":1,"retained_jobs":2}"#),
    (.job(job),
     #"{"response":"job","job_id":"j-1","kind":"scan","status":"running","created_at_ms":1,"latest_seq":2,"cancel_requested":false,"from_previous_run":false}"#),
    (.job(failedApply),
     #"{"response":"job","job_id":"j-1","kind":"apply","status":"failed","created_at_ms":1,"finished_at_ms":5,"latest_seq":2,"cancel_requested":false,"from_previous_run":false,"error":{"code":"manifest_load","message":"m"}}"#),
    (.jobs([job]),
     #"{"response":"jobs","jobs":[{"job_id":"j-1","kind":"scan","status":"running","created_at_ms":1,"latest_seq":2,"cancel_requested":false,"from_previous_run":false}]}"#),
    (.progress(job: job, events: [event], truncated: true),
     #"{"response":"progress","job":{"job_id":"j-1","kind":"scan","status":"running","created_at_ms":1,"latest_seq":2,"cancel_requested":false,"from_previous_run":false},"events":[{"seq":1,"at_ms":0,"stage":"s","message":"m"}],"truncated":true}"#),
    (.jobResult(.scan(report: emptyScan)),
     #"{"response":"job_result","kind":"scan","report":{"homebrew":{"available":false,"packages_enumerated":false,"formulae":[],"casks":[],"diagnostics":[]},"configs":[],"diagnostics":[]}}"#),
    (.jobResult(.plan(plan: Plan(schema: 1, profile: nil, manifestPath: FilePath("/m.toml"), home: FilePath("/h"), repoRoot: FilePath("/r"), actions: [], stateFingerprint: "f"), planId: "p-x")),
     #"{"response":"job_result","kind":"plan","plan":{"schema":1,"profile":null,"manifest_path":"/m.toml","home":"/h","repo_root":"/r","actions":[],"state_fingerprint":"f"},"plan_id":"p-x"}"#),
    (.jobResult(.apply(journal: RunJournal(runId: "r-1", planDigest: "d", steps: [StepRecord(actionId: "a-001", status: .done, atMs: 3)]))),
     #"{"response":"job_result","kind":"apply","journal":{"run_id":"r-1","plan_digest":"d","steps":[{"action_id":"a-001","status":"done","at_ms":3}]}}"#),
    (.shuttingDown, #"{"response":"shutting_down"}"#),
    (.approval(ApprovalGrant(token: "secret", expiresAtMs: 10)), #"{"response":"approval","token":"secret","expires_at_ms":10}"#),
    (.runs([RunSummary(runId: "r-1", planId: "p-1", planDigest: "d", jobId: "j-1", status: .interrupted)]),
     #"{"response":"runs","runs":[{"run_id":"r-1","plan_id":"p-1","plan_digest":"d","job_id":"j-1","status":"interrupted"}]}"#),
    (.run(RunView(runId: "r-1", planDigest: "d", steps: [], status: .succeeded, planId: "p-1", jobId: "j-1")),
     #"{"response":"run","run_id":"r-1","plan_digest":"d","steps":[],"status":"succeeded","plan_id":"p-1","job_id":"j-1"}"#),
    (.run(RunView(runId: "r-1", planDigest: "", steps: [], status: .interrupted, planId: "p-1", jobId: "j-1",
                  notResumable: NotResumable(reason: "missing_plan_digest", message: "m"))),
     #"{"response":"run","run_id":"r-1","plan_digest":"","steps":[],"status":"interrupted","plan_id":"p-1","job_id":"j-1","not_resumable":{"reason":"missing_plan_digest","message":"m"}}"#),
]
