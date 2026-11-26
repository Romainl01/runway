import Foundation
import RunwayCore

/// Stand-ins for the real scanner and stopper (QA mode, and live mode until the system scanner lands).
/// Neutral data only: names, projects and conversation titles are made up.
enum FixtureMemory {
    private static let gib: UInt64 = 1_073_741_824

    private static func gb(_ value: Double) -> UInt64 { UInt64(value * Double(gib)) }

    /// A Mac at medium pressure, 26.1 of 32 GB used, with something to suggest in every group.
    static func snapshot(now: Date) -> MemorySnapshot {
        MemorySnapshot(
            usedBytes: gb(26.1), totalBytes: 32 * gib, pressure: .warning, swapUsedBytes: gb(6.4),
            groups: [
                MemoryGroup(kind: .simulators, items: [
                    MemoryItem(id: "sim-iphone-16-pro", group: .simulators, name: "iPhone 16 Pro", context: "my-app",
                               bytes: gb(2.1), reason: .idle(since: now.addingTimeInterval(-2 * 3600 - 300)),
                               target: .simulator(udid: "FIXTURE-0001")),
                    MemoryItem(id: "sim-iphone-se", group: .simulators, name: "iPhone SE",
                               bytes: gb(1.1), reason: .noAppOpen, target: .simulator(udid: "FIXTURE-0002")),
                ]),
                MemoryGroup(kind: .servers, items: [
                    MemoryItem(id: "srv-my-app", group: .servers, name: "my-app", context: "expo start", ports: [8081],
                               bytes: gb(2.0), reason: .orphan, target: .process(pid: 40_101, startTime: 1)),
                    MemoryItem(id: "srv-web", group: .servers, name: "web", context: "next dev", ports: [3000],
                               bytes: gb(0.8), target: .process(pid: 40_102, startTime: 1)),
                ]),
                MemoryGroup(kind: .claude, items: [
                    MemoryItem(id: "claude-paywall", group: .claude, name: "Fix the onboarding paywall", context: "my-app",
                               bytes: gb(0.6), reason: .noMessage(since: now.addingTimeInterval(-5 * 3600 - 600)),
                               target: .process(pid: 40_201, startTime: 1)),
                    MemoryItem(id: "claude-dark-mode", group: .claude, name: "Add dark mode", context: "web",
                               bytes: gb(0.4), target: .process(pid: 40_202, startTime: 1)),
                ]),
                MemoryGroup(kind: .apps, items: [
                    MemoryItem(id: "app-notes", group: .apps, name: "Notes", context: "5 windows",
                               bytes: gb(2.9), target: .app(pid: 40_301, startTime: 1)),
                    MemoryItem(id: "app-browser", group: .apps, name: "Browser", context: "14 tabs",
                               bytes: gb(2.6), target: .app(pid: 40_302, startTime: 1)),
                    MemoryItem(id: "app-chat", group: .apps, name: "Chat", context: "3 workspaces",
                               bytes: gb(0.6), target: .app(pid: 40_303, startTime: 1)),
                ]),
            ],
            scannedAt: now)
    }
}

struct FixtureMemoryScanner: MemoryScanning {
    func scan(now: Date) async -> MemorySnapshot { FixtureMemory.snapshot(now: now) }
}

/// Pretends to stop: waits 2 s, then reports the target gone.
struct NoopMemoryStopper: MemoryStopping {
    func stop(_ target: MemoryTarget) async -> StopOutcome {
        try? await Task.sleep(for: .seconds(2))
        return .stopped
    }

    func forceStop(_ target: MemoryTarget) async -> StopOutcome { await stop(target) }
}
