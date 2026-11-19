// Ported subset of crates/dotfilesync-daemon/tests/ipc_security_tests.rs: the request
// validation, authorization and data-directory checks that remain above the transport.
// Framing, handshake, peer-credential, socket and connection-limit tests are not applicable
// (XPC replaces that layer); see the step report for the full classification.

import Agent
import Core
import Darwin
import Foundation
import IPC
import System
import Testing

private func json(_ s: String) -> Data { Data(s.utf8) }

@Suite(.serialized) struct SecurityTests {
    // ipc_security_tests.rs: client_handshake_ping_and_info_over_temp_socket (info part)
    @Test func pingAndDaemonInfo() throws {
        let env = try Env(.fast)
        let d = try env.start()
        defer { d.shutdown() }
        #expect(try d.call(.ping) == .pong)
        guard case let .daemonInfo(info) = try d.call(.daemonInfo) else {
            Issue.record("expected daemon_info")
            return
        }
        #expect(info.protocolVersion == 1)
        #expect(info.pid == UInt32(getpid()))
        #expect(info.dataDir == env.layout.root)
        #expect(info.activeJobs == 0)
    }

    // ipc_security_tests.rs: wrong_uid_peer_is_rejected_before_handshake /
    // request_cannot_claim_a_uid (authorization logic; the peer UID comes from the transport)
    @Test func foreignCallerIsRejectedAndLogged() throws {
        let env = try Env(.fast)
        let d = try env.start()
        defer { d.shutdown() }
        let foreign = geteuid() + 1
        guard case let .err(e) = d.handle(.ping, callerUid: foreign) else {
            Issue.record("foreign caller accepted")
            return
        }
        #expect(e.code == .unauthorized)
        #expect(e.message.contains("only the user"))
        // A uid field inside params is not part of any request and changes nothing.
        guard case let .err(e2) = d.handle(json: json(#"{"op":"ping","params":{"uid":\#(geteuid())}}"#), callerUid: foreign) else {
            Issue.record("foreign caller accepted")
            return
        }
        #expect(e2.code == .unauthorized)
        #expect(d.watch(jobId: "j-x", sinceSeq: 0, callerUid: foreign) { (_: IPC.Notification) in true } == .err(e))
        #expect(readText(env.layout.logFile).contains("rejected connection from uid \(foreign)"))
        // The owner (explicitly or by default) is accepted.
        #expect(d.handle(.ping, callerUid: geteuid()) == .ok(.pong))
    }

    // ipc_security_tests.rs: malformed_requests_get_typed_errors_and_daemon_stays_healthy
    @Test func malformedRequestsGetTypedErrorsAndAgentStaysHealthy() throws {
        let env = try Env(.fast)
        let d = try env.start()
        defer { d.shutdown() }
        func code(_ body: String) -> ErrorCode? {
            if case let .err(e) = d.handle(json: json(body)) { return e.code }
            return nil
        }
        #expect(code(#"{"op":7}"#) == .malformedRequest)
        #expect(code(#"{"op":"exec","params":{"cmd":"id"}}"#) == .unknownOperation)
        guard case let .err(reserved) = d.handle(json: json(#"{"op":"runtime.x","params":{}}"#)) else {
            Issue.record("reserved op accepted")
            return
        }
        #expect(reserved.code == .unsupportedOperation)
        #expect(reserved.message.contains("#5"))
        #expect(code(#"{"op":"sync.push"}"#) == .unsupportedOperation)
        #expect(code(#"{"op":"config.future"}"#) == .unknownOperation)
        #expect(code(#"{"op":"start_job","params":{"spec":{"kind":"scan","manifest":null,"home":"relative/home","repo_root":null}}}"#) == .invalidParams)
        #expect(d.handle(json: json(#"{"op":"ping"}"#)) == .ok(.pong))
        #expect(code("\u{FF}\u{FE} not json") == .malformedRequest)
        #expect(try d.call(.ping) == .pong)
    }

    // ipc_security_tests.rs: oversized_frame_is_rejected_without_allocation (size bound only)
    @Test func oversizedRequestIsRejected() throws {
        let env = try Env(.fast)
        let d = try env.start()
        defer { d.shutdown() }
        let big = Data(repeating: 0x20, count: MAX_REQUEST_BYTES + 1)
        guard case let .err(e) = d.handle(json: big) else {
            Issue.record("oversized request accepted")
            return
        }
        #expect(e.code == .frameTooLarge)
        #expect(try d.call(.ping) == .pong)
    }

    @Test func requestValidationRejectsBadIdsTokensAndPaths() throws {
        let env = try Env(.fast)
        let d = try env.start()
        defer { d.shutdown() }
        #expect(errorCode { try d.planApprove("../etc", "d") }?.code == .invalidParams)
        #expect(errorCode { try d.planApprove("p-unknown", "d") }?.code == .planNotFound)
        #expect(errorCode { try d.planApply("p-unknown", "", false) }?.code == .invalidParams)
        #expect(errorCode { try d.planApply("p-unknown", "t\n", false) }?.code == .invalidParams)
        #expect(errorCode { try d.planApply("p-unknown", String(repeating: "a", count: 257), false) }?.code == .invalidParams)
        #expect(errorCode { try d.planRunStatus("r/x") }?.code == .invalidParams)
        #expect(errorCode { try d.planRunStatus("r-none") }?.code == .planNotFound)
        let longPath = FilePath("/" + String(repeating: "a", count: 5000))
        #expect(errorCode { try d.startJob(.scan(ScanInput(manifest: nil, home: longPath))) }?.code == .invalidParams)
        let badProfile = PlanInput(manifest: FilePath("/m.toml"), home: env.home, profile: "a/b")
        #expect(errorCode { try d.planCreate(badProfile) }?.code == .invalidParams)
    }

    // ipc_security_tests.rs: private_permissions_on_dirs_socket_and_state (dirs + state files)
    @Test func privatePermissionsOnDirsAndState() throws {
        let env = try Env(.fast)
        let d = try env.start()
        defer { d.shutdown() }
        let l = env.layout
        for dir in [l.root, l.stateDir, l.runsDir, l.backupsDir, l.logsDir] {
            #expect(modeOf(dir) == 0o700, "\(dir)")
        }
        for file in [l.journal, l.logFile] {
            #expect(modeOf(file) == 0o600, "\(file)")
        }
    }

    // ipc_security_tests.rs: refuses_permissive_or_symlinked_data_dir_and_client_refuses_too
    // (agent side; the client-side check belongs to the CLI step)
    @Test func refusesPermissiveOrSymlinkedDataDir() throws {
        let env = try Env(.fast)
        try FileManager.default.createDirectory(atPath: env.layout.root.string, withIntermediateDirectories: true)
        chmod(env.layout.root.string, 0o755)
        #expect(throws: AgentError.self) { try env.start() }
        #expect(modeOf(env.layout.root) == 0o755, "we never silently repair permissions")
        #expect(throws: PathError.tooPermissive(path: env.layout.root, mode: 0o755)) {
            try checkPrivateDir(env.layout.root)
        }

        let env2 = try Env(.fast)
        let real = env2.tmp.appending("real")
        try FileManager.default.createDirectory(atPath: real.string, withIntermediateDirectories: false)
        chmod(real.string, 0o700)
        symlink(real.string, env2.layout.root.string)
        do {
            _ = try env2.start()
            Issue.record("symlinked data dir accepted")
        } catch let error as AgentError {
            // Not `catch let AgentError.path(…)`: crashes the Xcode 26 SIL ownership verifier.
            guard case let .path(pathError) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(pathError == .symlink(path: env2.layout.root))
        }
    }

    // ipc_security_tests.rs: source_has_no_network_listener_or_command_endpoint
    @Test func sourceHasNoNetworkListenerOrCommandEndpoint() throws {
        let sources = repoRoot.appending("Packages/DotfileSyncKit/Sources")
        for target in ["Agent", "IPC"] {
            let dir = sources.appending(target)
            let files = try FileManager.default.subpathsOfDirectory(atPath: dir.string).filter { $0.hasSuffix(".swift") }
            #expect(!files.isEmpty)
            for f in files {
                let src = readText(dir.appending(f))
                for banned in ["NWListener", "NWConnection", "socket(", "AF_INET", "\"/bin/sh\"", "Process()", "posix_spawn"] {
                    #expect(!src.contains(banned), "\(target)/\(f) contains \(banned)")
                }
            }
        }
    }
}
