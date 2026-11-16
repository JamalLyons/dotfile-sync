// Display summaries of agent results. Pure values so tests can check them without any UI.

import Core
import Foundation
import IPC

struct StateCount: Equatable, Sendable {
    var state: String
    var count: Int
}

struct ScanSummary: Equatable, Sendable {
    var homebrewAvailable: Bool
    var brewVersion: String?
    var formulae: Int
    var casks: Int
    var configs: Int
    /// Config count per state (`matching`, `changed`, …), sorted by state name.
    var configStates: [StateCount]
    var diagnostics: [String]

    init(_ report: ScanReport) {
        homebrewAvailable = report.homebrew.available
        brewVersion = report.homebrew.brewVersion
        formulae = report.homebrew.formulae.count
        casks = report.homebrew.casks.count
        configs = report.configs.count
        configStates = Dictionary(grouping: report.configs, by: { $0.state.rawValue })
            .map { StateCount(state: $0.key, count: $0.value.count) }
            .sorted { $0.state < $1.state }
        diagnostics = (report.homebrew.diagnostics + report.diagnostics).map(describe)
    }
}

struct StatusOverview: Equatable, Sendable {
    var homebrewAvailable: Bool
    var summary: StatusSummary
    var diagnostics: [String]

    init(_ report: StatusReport) {
        homebrewAvailable = report.homebrewAvailable
        summary = report.summary
        diagnostics = report.diagnostics.map(describe)
    }

    /// True when nothing is missing, changed or unknown.
    var inSync: Bool {
        summary.packagesMissing == 0 && summary.packagesUnknown == 0
            && summary.configsChanged == 0 && summary.configsMissing == 0 && summary.configsUnknown == 0
    }
}

struct PlannedAction: Equatable, Sendable, Identifiable {
    var id: String
    var summary: String
    var risk: Risk
    var reversible: Bool
    var backup: Bool
}

/// A plan the agent created and can approve. Carries the id and digest the approval binds to.
struct PlanSummary: Equatable, Sendable {
    var planId: String
    var digest: String
    var profile: String?
    var actions: [PlannedAction]

    init(plan: Plan, planId: String) {
        self.planId = planId
        digest = plan.digest
        profile = plan.profile
        actions = plan.actions.map {
            PlannedAction(id: $0.id, summary: $0.summary, risk: $0.risk, reversible: $0.reversible, backup: $0.backup)
        }
    }

    var isEmpty: Bool { actions.isEmpty }
    var highRiskCount: Int { actions.filter { $0.risk == .high }.count }
}

struct ApplySummary: Equatable, Sendable {
    var runId: String
    var done: Int
    var failed: Int
    var skipped: Int
    var errors: [String]

    init(_ journal: RunJournal) {
        runId = journal.runId
        // The journal records transitions; the last record per action is its final state.
        var last: [String: StepRecord] = [:]
        var order: [String] = []
        for step in journal.steps {
            if last[step.actionId] == nil { order.append(step.actionId) }
            last[step.actionId] = step
        }
        let finals = order.compactMap { last[$0] }
        done = finals.filter { $0.status == .done }.count
        failed = finals.filter { $0.status == .failed }.count
        skipped = finals.filter { $0.status == .skipped }.count
        errors = finals.compactMap { record in record.error.map { "\(record.actionId): \($0)" } }
    }
}

private func describe(_ diagnostic: Diagnostic) -> String {
    "\(diagnostic.severity.rawValue): \(diagnostic.message)"
}
