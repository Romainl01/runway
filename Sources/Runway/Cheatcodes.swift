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

    /// Memory scenarios only: a row shown hovered (Stop visible) or with its confirmation open.
    var memoryHoverID: String?
    var memoryConfirmID: String?

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

/// Memory tab scenarios (RUNWAY_SCENARIO=mem-<id>), drawn over the live scan by `RAMStore.simulate`.
enum MemoryScenario: String, CaseIterable, Identifiable {
    case medium, calm, critical, hover, confirm, stopping, stopped, busy, loading, overflow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .medium: tr("Memory · medium pressure")
        case .calm: tr("Memory · calm")
        case .critical: tr("Memory · critical, not responding")
        case .hover: tr("Memory · row hovered")
        case .confirm: tr("Memory · stop confirmation")
        case .stopping: tr("Memory · stopping")
        case .stopped: tr("Memory · stopped")
        case .busy: tr("Memory · Claude answering")
        case .loading: tr("Memory · loading")
        case .overflow: tr("Memory · overflow")
        }
    }

    /// "mem-calm" -> .calm
    init?(launchID: String) {
        guard launchID.hasPrefix("mem-") else { return nil }
        self.init(rawValue: String(launchID.dropFirst(4)))
    }

    @MainActor
    func apply(to ram: RAMStore) {
        let cheats = Cheatcodes.shared
        cheats.memoryHoverID = nil
        cheats.memoryConfirmID = nil
        var snapshot = FixtureMemory.snapshot(now: ram.now())
        let gib: UInt64 = 1_073_741_824
        var states: [String: StopState] = [:]

        func edit(_ id: String, _ change: (inout MemoryItem) -> Void) {
            for g in snapshot.groups.indices {
                for i in snapshot.groups[g].items.indices where snapshot.groups[g].items[i].id == id {
                    change(&snapshot.groups[g].items[i])
                }
            }
        }

        switch self {
        case .medium:
            break
        case .calm:
            snapshot.pressure = .normal
            snapshot.usedBytes = gib * 14 + gib / 5
            for g in snapshot.groups.indices {
                for i in snapshot.groups[g].items.indices { snapshot.groups[g].items[i].reason = nil }
            }
        case .critical:
            snapshot.pressure = .critical
            snapshot.usedBytes = gib * 31 + gib * 2 / 5
            states["srv-my-app"] = .notResponding
        case .hover:
            cheats.memoryHoverID = "sim-iphone-16-pro"
        case .confirm:
            cheats.memoryHoverID = "sim-iphone-16-pro"
            cheats.memoryConfirmID = "sim-iphone-16-pro"
        case .stopping:
            cheats.memoryHoverID = "sim-iphone-16-pro"
            states["sim-iphone-16-pro"] = .stopping
        case .stopped:
            states["sim-iphone-16-pro"] = .stopped(freedBytes: gib * 21 / 10)
        case .busy:
            edit("claude-dark-mode") { $0.isBusy = true }
            cheats.memoryHoverID = "claude-dark-mode"
            cheats.memoryConfirmID = "claude-dark-mode"
        case .loading:
            ram.simulate(MemoryPresentation(snapshot: nil))
            return
        case .overflow:
            edit("sim-iphone-16-pro") {
                $0.name = "iPhone 16 Pro Max with an extremely long device name"
                $0.context = "A very long application name that goes on and on"
            }
            edit("srv-my-app") {
                $0.name = "my-app-with-a-very-long-project-name-in-a-monorepo"
                $0.context = "expo start --dev-client --clear --port 8081"
            }
            edit("claude-paywall") {
                $0.name = "Fix the onboarding paywall and then rework the whole settings screen layout"
                $0.context = "my-app-with-a-very-long-project-name-in-a-monorepo"
            }
            edit("app-browser") { $0.name = "A browser whose name is far too long to fit on one line"; $0.bytes = gib * 12 + gib / 3 }
        }
        ram.simulate(MemoryPresentation(snapshot: snapshot, stopStates: states))
    }
}

/// The context menu itself.
struct CheatcodeMenu: View {
    let store: UsageStore
    let ram: RAMStore
    @Bindable private var cheats = Cheatcodes.shared

    init(store: UsageStore, ram: RAMStore) {
        self.store = store
        self.ram = ram
    }

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
        Section("Memory") {
            ForEach(MemoryScenario.allCases) { scenario in
                Button(scenario.label) { scenario.apply(to: ram) }
            }
        }
        Divider()
        Button("Back to live data") {
            store.resumeLive()
            cheats.memoryHoverID = nil
            cheats.memoryConfirmID = nil
            ram.resumeLive()
        }
        .disabled(!store.isSimulating && !ram.isSimulating)
    }
}
