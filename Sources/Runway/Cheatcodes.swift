import AppKit
import Observation
import RunwayCore
import SwiftUI

/// Cheatcodes: right-click on the popover header. Theme and test scenarios, never shipped as a setting.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark, glass
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: tr("System")
        case .light: tr("Light")
        case .dark: tr("Dark")
        case .glass: tr("Liquid glass")
        }
    }

    /// QA: RUNWAY_THEME=system|light|dark|glass.
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> AppTheme {
        AppTheme(rawValue: env["RUNWAY_THEME"] ?? "") ?? .system
    }
}

@MainActor
@Observable
final class Cheatcodes {
    static let shared = Cheatcodes()

    var theme: AppTheme = .fromEnvironment() {
        didSet { applyAppearance() }
    }

    /// Glass follows the system appearance, like the real macOS material.
    func applyAppearance() {
        NSApp.appearance = switch theme {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system, .glass: nil
        }
    }
}

/// Test scenarios: each one covers a state the craft bar asks to see before calling a screen done.
enum Scenario: String, CaseIterable, Identifiable {
    case calm, warning, critical, creditsCap, overflow, personal
    case loading, offline, expired, claudeCodeMissing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calm: tr("Normal · 18%")
        case .warning: tr("Warning · 86%")
        case .critical: tr("Critical · 97%")
        case .creditsCap: tr("Credits · cap reached")
        case .overflow: tr("Overflow · long text")
        case .personal: tr("Personal account")
        case .loading: tr("Loading")
        case .offline: tr("Offline")
        case .expired: tr("Connection expired")
        case .claudeCodeMissing: tr("Claude Code missing")
        }
    }

    /// Connection states, as opposed to data scenarios.
    var isState: Bool { [.loading, .offline, .expired, .claudeCodeMissing].contains(self) }
    static var data: [Scenario] { allCases.filter { !$0.isState } }
    static var states: [Scenario] { allCases.filter(\.isState) }

    @MainActor
    func apply(to store: UsageStore) {
        let now = store.now()
        let team = store.account ?? ClaudeAccount(email: "you@example.com", kind: .team, organizationName: "Acme")
        let fetched = now.addingTimeInterval(-5)

        func snapshot(session: Double, weekly: Double, scoped: [(String, Double)] = [("Fable", 0)],
                      credits: UsageCredits? = nil, fetchedAt: Date = fetched) -> UsageSnapshot {
            UsageSnapshot(
                session: UsageLimit(kind: .session, percent: session, resetsAt: now.addingTimeInterval(90 * 60)),
                weekly: UsageLimit(kind: .weeklyAll, percent: weekly, resetsAt: now.addingTimeInterval(4 * 86400)),
                scoped: scoped.map { UsageLimit(kind: .weeklyScoped, modelName: $0.0, percent: $0.1,
                                                resetsAt: now.addingTimeInterval(4 * 86400)) },
                credits: credits,
                fetchedAt: fetchedAt)
        }
        let calm = snapshot(session: 18, weekly: 73)
        func show(_ state: ConnectionState, _ snapshot: UsageSnapshot?, plan: String? = "Max 5x",
                  account: ClaudeAccount? = nil) {
            store.simulate(Presentation(state: state, snapshot: snapshot, plan: plan, account: account ?? team))
        }

        switch self {
        case .calm:
            show(.ok, calm)
        case .warning:
            show(.ok, snapshot(session: 86, weekly: 81))
        case .critical:
            show(.ok, snapshot(session: 97, weekly: 96, scoped: [("Fable", 95)]))
        case .creditsCap:
            show(.ok, snapshot(session: 100, weekly: 88, credits: UsageCredits(used: 30.80, limit: 30, currency: "EUR")))
        case .overflow:
            show(.ok,
                 snapshot(session: 42, weekly: 64,
                          scoped: [("Fable", 12), ("Opus 5.5 avec un nom de modèle très long", 99), ("Sonnet 5.5", 3)],
                          credits: UsageCredits(used: 1234.56, limit: 5000, currency: "EUR")),
                 plan: "Max 20x",
                 account: ClaudeAccount(email: "prenom.nom-tres-long@une-entreprise-au-nom-interminable.com",
                                        kind: .enterprise, organizationName: "Une entreprise au nom interminable"))
        case .personal:
            show(.ok, calm, plan: "Pro", account: ClaudeAccount(email: "prenom@gmail.com", kind: .personal))
        case .loading:
            show(.loading, nil)
        case .offline:
            show(.offline(.network), snapshot(session: 18, weekly: 73, fetchedAt: now.addingTimeInterval(-12 * 60)))
        case .expired:
            show(.expired, snapshot(session: 18, weekly: 73, fetchedAt: now.addingTimeInterval(-3 * 3600)))
        case .claudeCodeMissing:
            store.simulate(Presentation(state: .claudeCodeMissing))
        }
    }
}

/// The context menu itself.
struct CheatcodeMenu: View {
    let store: UsageStore
    @Bindable private var cheats = Cheatcodes.shared

    init(store: UsageStore) { self.store = store }

    var body: some View {
        Picker("Theme", selection: $cheats.theme) {
            ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        Section("Data") {
            ForEach(Scenario.data) { scenario in
                Button(scenario.label) { scenario.apply(to: store) }
            }
        }
        Section("States") {
            ForEach(Scenario.states) { scenario in
                Button(scenario.label) { scenario.apply(to: store) }
            }
        }
        Divider()
        Button("Back to live data") { store.resumeLive() }
            .disabled(!store.isSimulating)
    }
}
