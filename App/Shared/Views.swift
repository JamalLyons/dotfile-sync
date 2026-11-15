// SwiftUI shell: agent status and registration, scan/status/plan summaries, and a
// Touch ID-gated apply.

import AgentRegistration
import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

/// The app's window content, wired to the real agent, SMAppService and LocalAuthentication.
struct DotfileSyncRootView: View {
    @State private var model: AppModel

    init() {
        _model = State(initialValue: AppModel(
            registration: AgentRegistration(),
            agent: LiveAgentClient(),
            gate: LocalAuthenticationGate()
        ))
    }

    init(model: AppModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationSplitView {
            List {
                AgentSection(model: model)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    InputsSection(model: model)
                    ResultsSection(model: model)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            model.refreshRegistration()
            await model.checkAgent()
        }
    }
}

// MARK: - Agent

private struct AgentSection: View {
    let model: AppModel

    var body: some View {
        Section("Agent") {
            LabeledContent("Registration", value: model.registrationStatus.label)
            LabeledContent("Agent") { ReachabilityLabel(reachability: model.reachability) }
            if let message = model.registrationMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Button("Register") { model.register() }
                .disabled(model.registrationStatus == .enabled || model.registrationStatus == .requiresApproval)
            Button("Unregister") { model.unregister() }
                .disabled(model.registrationStatus == .notRegistered || model.registrationStatus == .notFound)
            Button("Open Login Items Settings") { model.openLoginItems() }
            Button("Check Agent") { Task { await model.checkAgent() } }
        }
    }
}

private struct ReachabilityLabel: View {
    let reachability: AgentReachability

    var body: some View {
        switch reachability {
        case .unknown: Text("Not checked")
        case .checking: ProgressView().controlSize(.small)
        case let .reachable(version, protocolVersion, pid, activeJobs):
            Text("v\(version) · protocol \(protocolVersion) · pid \(pid) · \(activeJobs) active")
                .foregroundStyle(.green)
        case let .unreachable(reason):
            Text("Unreachable").foregroundStyle(.red).help(reason)
        }
    }
}

extension AgentRegistrationStatus {
    var label: String {
        switch self {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Needs approval in Login Items"
        case .notFound: return "Not found in app bundle"
        }
    }
}

// MARK: - Inputs and actions

private struct InputsSection: View {
    @Bindable var model: AppModel
    @State private var choosingManifest = false

    var body: some View {
        GroupBox("Manifest") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("/path/to/dotfilesync.toml", text: $model.manifestPath)
                    Button("Choose…") { choosingManifest = true }
                }
                TextField("Home directory", text: $model.homePath)
                TextField("Profile (optional)", text: $model.profile)
                HStack {
                    Button("Scan") { Task { await model.runScan() } }
                    Button("Status") { Task { await model.runStatus() } }
                    Button("Plan") { Task { await model.runPlan() } }
                }
                .disabled(model.isBusy)
            }
            .padding(4)
        }
        .fileImporter(isPresented: $choosingManifest, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                model.manifestPath = url.path(percentEncoded: false)
            }
        }
    }
}

// MARK: - Results

private struct ResultsSection: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .idle: EmptyView()
        case let .running(label):
            HStack { ProgressView().controlSize(.small); Text("\(label)…") }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
        if !model.progress.isEmpty {
            GroupBox("Progress") {
                VStack(alignment: .leading) {
                    ForEach(Array(model.progress.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let scan = model.scan { ScanView(scan: scan) }
        if let status = model.status { StatusView(status: status) }
        if let plan = model.plan { PlanView(plan: plan, model: model) }
        ApplyStateView(state: model.apply)
    }
}

private struct ScanView: View {
    let scan: ScanSummary

    var body: some View {
        GroupBox("Scan") {
            VStack(alignment: .leading, spacing: 4) {
                Text(scan.homebrewAvailable ? "Homebrew \(scan.brewVersion ?? "")" : "Homebrew not found")
                Text("\(scan.formulae) formulae, \(scan.casks) casks, \(scan.configs) tracked configs")
                ForEach(scan.configStates, id: \.state) { entry in
                    Text("  \(entry.state): \(entry.count)").font(.callout)
                }
                DiagnosticsList(lines: scan.diagnostics)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatusView: View {
    let status: StatusOverview

    var body: some View {
        let s = status.summary
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 4) {
                Label(status.inSync ? "In sync" : "Out of sync",
                      systemImage: status.inSync ? "checkmark.circle" : "exclamationmark.circle")
                Text("Packages: \(s.packagesMatching) matching, \(s.packagesMissing) missing, \(s.packagesUnmanaged) unmanaged, \(s.packagesUnknown) unknown")
                Text("Configs: \(s.configsMatching) matching, \(s.configsChanged) changed, \(s.configsMissing) missing, \(s.configsUnknown) unknown, \(s.configsSkipped) skipped")
                DiagnosticsList(lines: status.diagnostics)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PlanView: View {
    let plan: PlanSummary
    let model: AppModel

    var body: some View {
        GroupBox("Plan \(plan.planId)") {
            VStack(alignment: .leading, spacing: 4) {
                if plan.isEmpty {
                    Text("Nothing to apply.")
                } else {
                    ForEach(plan.actions) { action in
                        HStack(alignment: .firstTextBaseline) {
                            Text(action.id).font(.caption.monospaced())
                            Text(action.summary)
                            Spacer()
                            Text(action.risk.rawValue).foregroundStyle(action.risk == .high ? .red : .secondary)
                            if action.backup { Image(systemName: "archivebox").help("Backed up before replacing") }
                        }
                    }
                    Text("Digest \(plan.digest.prefix(12))…").font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await model.applyPlan() }
                    } label: {
                        Label("Apply \(plan.actions.count) actions…", systemImage: "touchid")
                    }
                    .disabled(!model.canApply)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ApplyStateView: View {
    let state: ApplyState

    var body: some View {
        switch state {
        case .idle: EmptyView()
        case .authenticating: Text("Waiting for Touch ID…")
        case .approving: Text("Requesting approval from the agent…")
        case let .applying(jobId): HStack { ProgressView().controlSize(.small); Text("Applying (job \(jobId))…") }
        case let .completed(summary):
            Label("Run \(summary.runId): \(summary.done) done, \(summary.failed) failed, \(summary.skipped) skipped",
                  systemImage: summary.failed == 0 ? "checkmark.circle" : "xmark.circle")
            DiagnosticsList(lines: summary.errors)
        case let .cancelled(message): Text(message).foregroundStyle(.secondary)
        case let .failed(message): Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}

private struct DiagnosticsList: View {
    let lines: [String]

    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
    }
}
