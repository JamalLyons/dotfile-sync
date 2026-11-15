import Foundation
import Synchronization
import ServiceManagement
import Testing

@testable import AgentRegistration

/// In-memory stand-in for `SMAppService`. Never touches launchd.
final class FakeBackend: AgentServiceBackend {
    struct State {
        var status: AgentRegistrationStatus
        var calls: [String] = []
        var failNext: String?
        var registerLandsIn: AgentRegistrationStatus = .enabled
    }

    let state: Mutex<State>

    init(_ status: AgentRegistrationStatus) {
        state = Mutex(State(status: status))
    }

    var status: AgentRegistrationStatus { state.withLock { $0.status } }
    var calls: [String] { state.withLock { $0.calls } }

    func register() throws {
        try state.withLock { s in
            s.calls.append("register")
            if let message = s.failNext {
                s.failNext = nil
                throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            s.status = s.registerLandsIn
        }
    }

    func unregister() throws {
        try state.withLock { s in
            s.calls.append("unregister")
            if let message = s.failNext {
                s.failNext = nil
                throw NSError(domain: "fake", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
            s.status = .notRegistered
        }
    }

    func openSystemSettingsLoginItems() {
        state.withLock { $0.calls.append("open_login_items") }
    }
}

@Suite struct AgentRegistrationTests {
    // Ports install_writes_plist_but_never_loads_or_starts: registering only makes the
    // definition known; it does not start the agent (no RunAtLoad, launched on demand).
    @Test func registerOnlyRegisters() throws {
        let fake = FakeBackend(.notRegistered)
        let reg = AgentRegistration(backend: fake)
        #expect(try reg.register() == .registered)
        #expect(fake.calls == ["register"])
        #expect(reg.status == .enabled)
    }

    // Ports start_at_login_is_explicit_and_reinstall_is_idempotent (idempotent half).
    @Test func registerIsIdempotent() throws {
        for status in [AgentRegistrationStatus.enabled, .requiresApproval] {
            let fake = FakeBackend(status)
            let reg = AgentRegistration(backend: fake)
            #expect(try reg.register() == .alreadyRegistered)
            #expect(fake.calls.isEmpty, "no second register call when already \(status)")
        }
    }

    // SMAppService reports `notFound` for an agent that was never registered, even when the plist
    // is in the bundle, so register is still attempted and succeeds.
    @Test func registerFromNotFoundStatusStillRegisters() throws {
        let fake = FakeBackend(.notFound)
        let reg = AgentRegistration(backend: fake)
        #expect(try reg.register() == .registered)
        #expect(fake.calls == ["register"])
        #expect(reg.status == .enabled)
    }

    // Ports start_requires_install_then_bootstraps_and_kickstarts: without the definition in
    // the bundle there is nothing to register, and the error says why.
    @Test func registerWithoutBundledPlistFailsClearly() {
        let fake = FakeBackend(.notFound)
        fake.state.withLock {
            $0.failNext = "Invalid argument"
            $0.registerLandsIn = .notFound
        }
        let reg = AgentRegistration(backend: fake)
        do {
            _ = try reg.register()
            Issue.record("expected failure")
        } catch {
            #expect(error.status == .notFound)
            #expect(error.description.contains("not in the app bundle"))
            #expect(error.description.contains("Invalid argument"))
        }
        #expect(fake.calls == ["register"])
    }

    @Test func registerNeedingApprovalIsReported() throws {
        let fake = FakeBackend(.notRegistered)
        fake.state.withLock { $0.registerLandsIn = .requiresApproval }
        let reg = AgentRegistration(backend: fake)
        #expect(try reg.register() == .registered)
        #expect(reg.status == .requiresApproval)
        reg.openSystemSettingsLoginItems()
        #expect(fake.calls == ["register", "open_login_items"])
    }

    @Test func backendFailureIsWrapped() {
        let fake = FakeBackend(.notRegistered)
        fake.state.withLock { $0.failNext = "Operation not permitted" }
        let reg = AgentRegistration(backend: fake)
        do {
            _ = try reg.register()
            Issue.record("expected failure")
        } catch {
            #expect(error.description == "cannot register the agent: Operation not permitted")
            #expect(error.status == .notRegistered)
        }
    }

    // Ports stop_unloads_only_when_loaded.
    @Test func unregisterOnlyWhenRegistered() throws {
        for status in [AgentRegistrationStatus.notRegistered, .notFound] {
            let fake = FakeBackend(status)
            #expect(try AgentRegistration(backend: fake).unregister() == .notRegistered)
            #expect(fake.calls.isEmpty)
        }
        for status in [AgentRegistrationStatus.enabled, .requiresApproval] {
            let fake = FakeBackend(status)
            #expect(try AgentRegistration(backend: fake).unregister() == .unregistered)
            #expect(fake.calls == ["unregister"])
        }
    }

    // Ports uninstall_unloads_and_removes_only_our_definition_and_keeps_user_data: the
    // registration API has no access to the data directory, so it cannot remove user data.
    @Test func unregisterNeverTouchesUserData() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("dfs-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let marker = data.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: marker)

        let fake = FakeBackend(.enabled)
        #expect(try AgentRegistration(backend: fake).unregister() == .unregistered)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    // Covers mapStatus over every SMAppService.Status case (from the parallel S4b child run).
    @Test func statusMapsEverySMAppServiceCase() {
        #expect(mapStatus(.notRegistered) == .notRegistered)
        #expect(mapStatus(.enabled) == .enabled)
        #expect(mapStatus(.requiresApproval) == .requiresApproval)
        #expect(mapStatus(.notFound) == .notFound)
    }

    @Test func statusJSONIsSnakeCase() throws {
        let encoded = try JSONEncoder().encode(AgentRegistrationStatus.allCases)
        #expect(String(decoding: encoded, as: UTF8.self) == #"["not_registered","enabled","requires_approval","not_found"]"#)
        #expect(String(decoding: try JSONEncoder().encode(RegisterOutcome.alreadyRegistered), as: UTF8.self) == #""already_registered""#)
    }

    @Test func plistNameMatchesShippedFile() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = repoRoot.appendingPathComponent("App/LaunchAgents").appendingPathComponent(AGENT_PLIST_NAME)
        let data = try Data(contentsOf: plist)
        let dict = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let label = try #require(dict["Label"] as? String)
        #expect(AGENT_PLIST_NAME == label + ".plist")
        #expect(dict["BundleProgram"] as? String == "Contents/MacOS/dotfilesyncd")
        let mach = try #require(dict["MachServices"] as? [String: Bool])
        #expect(mach[label] == true)
        #expect(dict["RunAtLoad"] == nil, "start-at-login stays opt-in")
        #expect(dict["KeepAlive"] == nil)
    }
}
