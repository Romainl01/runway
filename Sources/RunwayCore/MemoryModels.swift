import Foundation

/// macOS memory pressure (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical).
/// It colours the memory gauge and the menu bar "Go", not the percentage used: a full RAM is fine
/// as long as the system does not have to compress or swap.
public enum MemoryPressure: Int, Equatable, Sendable, Comparable {
    case normal, warning, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum MemoryGroupKind: String, CaseIterable, Sendable {
    /// One booted iOS simulator device: every process under its `launchd_sim`.
    case simulators
    /// node / bun / deno / python with at least one listening port, grouped per project.
    case servers
    /// One Claude Code CLI conversation (`~/.claude/sessions/<pid>.json`) and its child processes.
    case claude
    /// Regular apps, helpers summed under their responsible app. Never stopped per renderer.
    case apps
}

/// What the Stop button does, with what it needs to target the right thing.
public enum MemoryTarget: Hashable, Sendable {
    /// `xcrun simctl shutdown <udid>`.
    case simulator(udid: String)
    /// SIGTERM, then SIGKILL on "Force stop". `startTime` is checked again right before signalling
    /// so a reused pid is never hit.
    case process(pid: Int32, startTime: UInt64)
    /// `NSRunningApplication.terminate()`, then `forceTerminate()`.
    case app(pid: Int32, startTime: UInt64)
}

/// Why stopping this item is a good idea. Only set when there is one: no reason, no amber dot.
public enum MemoryReason: Equatable, Sendable {
    /// Simulator with no app open.
    case noAppOpen
    /// Almost no CPU since that date (simulator, server).
    case idle(since: Date)
    /// Dev server whose terminal is gone (re-parented to launchd).
    case orphan
    /// Same project and same command as another, newer server.
    case duplicate
    /// Claude Code conversation idle since that date.
    case noMessage(since: Date)
}

public struct MemoryItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var group: MemoryGroupKind
    /// Human name: device, project, conversation title, app.
    public var name: String
    /// Second line before the reason: app in the simulator, ":8081 expo start", project, "5 windows".
    public var context: String?
    /// Listening ports, shown in mono inside the context for servers.
    public var ports: [Int]
    /// Phys footprint summed over the item's processes (Activity Monitor's Memory column).
    public var bytes: UInt64
    public var reason: MemoryReason?
    /// Claude Code is answering: stopping asks for a stronger confirmation.
    public var isBusy: Bool
    public var target: MemoryTarget?

    public init(id: String, group: MemoryGroupKind, name: String, context: String? = nil, ports: [Int] = [],
                bytes: UInt64, reason: MemoryReason? = nil, isBusy: Bool = false, target: MemoryTarget? = nil) {
        self.id = id
        self.group = group
        self.name = name
        self.context = context
        self.ports = ports
        self.bytes = bytes
        self.reason = reason
        self.isBusy = isBusy
        self.target = target
    }
}

public struct MemoryGroup: Identifiable, Equatable, Sendable {
    public var kind: MemoryGroupKind
    /// Largest first.
    public var items: [MemoryItem]
    public var id: MemoryGroupKind { kind }

    public init(kind: MemoryGroupKind, items: [MemoryItem]) {
        self.kind = kind
        self.items = items
    }
}

public struct MemorySnapshot: Equatable, Sendable {
    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var pressure: MemoryPressure
    /// Simulators, servers, Claude Code, apps, in that order; empty groups left out.
    public var groups: [MemoryGroup]
    public var scannedAt: Date

    public init(usedBytes: UInt64, totalBytes: UInt64, pressure: MemoryPressure, groups: [MemoryGroup], scannedAt: Date) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.pressure = pressure
        self.groups = groups
        self.scannedAt = scannedAt
    }

    public var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
    public var hasSuggestions: Bool { groups.contains { $0.items.contains { $0.reason != nil } } }
}

/// Where a Stop is at, per item. Lives in the store, not in the snapshot, so a rescan keeps it.
public enum StopState: Equatable, Sendable {
    case stopping
    /// Gone. Shown until the next scan drops the row.
    case stopped(freedBytes: UInt64)
    /// Still alive after the grace period: the row offers "Force stop".
    case notResponding
}

// MARK: Seams

/// Reads the system: processes, simulators, Claude Code sessions. `ActivityTracker` state (CPU
/// deltas, idle since) lives inside the scanner, which is why it is a class and called serially.
public protocol MemoryScanning: Sendable {
    func scan(now: Date) async -> MemorySnapshot
}

public enum StopOutcome: Equatable, Sendable {
    case stopped
    /// The target ignored SIGTERM / terminate for the grace period.
    case notResponding
    /// pid reused or already gone: nothing was signalled.
    case gone
}

public protocol MemoryStopping: Sendable {
    /// Graceful stop; returns once the target is gone or the grace period (~3 s) ran out.
    func stop(_ target: MemoryTarget) async -> StopOutcome
    /// SIGKILL / forceTerminate. Simulators: `simctl shutdown` again.
    func forceStop(_ target: MemoryTarget) async -> StopOutcome
}
