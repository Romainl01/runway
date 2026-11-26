import Foundation
import Observation

/// A cheatcode scenario for the Memory tab: a snapshot and the stop states to show over it.
public struct MemoryPresentation: Equatable, Sendable {
    public var snapshot: MemorySnapshot?
    public var stopStates: [String: StopState]

    public init(snapshot: MemorySnapshot?, stopStates: [String: StopState] = [:]) {
        self.snapshot = snapshot
        self.stopStates = stopStates
    }
}

/// Scans memory on a loop and runs the Stop buttons. No network, so no `CallGate`: a scan is a few
/// ms of libproc. Faster while the Memory tab is visible, slow otherwise (the menu bar shows the Go).
@MainActor
@Observable
public final class RAMStore {
    private var live: MemoryPresentation = MemoryPresentation(snapshot: nil)
    private var simulated: MemoryPresentation?
    /// Rows stopped a moment ago, kept on screen with "Stopped · 2.1 GB freed" after the scan drops them.
    private var ghosts: [String: (item: MemoryItem, until: Date)] = [:]

    public var snapshot: MemorySnapshot? { (simulated ?? live).snapshot }
    public var isSimulating: Bool { simulated != nil }

    /// While the Memory tab is on screen.
    public var isVisible = false {
        didSet { if isVisible != oldValue { restartLoop() } }
    }

    public static let visibleInterval: TimeInterval = 5
    public static let backgroundInterval: TimeInterval = 30
    public static let ghostDuration: TimeInterval = 4

    @ObservationIgnored private let scanner: any MemoryScanning
    @ObservationIgnored private let stopper: any MemoryStopping
    @ObservationIgnored public let now: @Sendable () -> Date
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var isScanning = false

    public init(scanner: any MemoryScanning, stopper: any MemoryStopping, now: @escaping @Sendable () -> Date = { Date() }) {
        self.scanner = scanner
        self.stopper = stopper
        self.now = now
    }

    public func start() {
        guard loopTask == nil else { return }
        restartLoop()
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scanOnce()
                let delay = self.isVisible ? Self.visibleInterval : Self.backgroundInterval
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    public func scanOnce() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let snap = await scanner.scan(now: now())
        live.snapshot = snap
        let ids = Set(snap.groups.flatMap { $0.items.map(\.id) })
        // A stop that is done or gave up leaves with its row; a ghost leaves after its delay.
        live.stopStates = live.stopStates.filter { id, state in
            switch state {
            case .stopping: true
            case .stopped: ghosts[id] != nil
            case .notResponding: ids.contains(id)
            }
        }
        let t = now()
        ghosts = ghosts.filter { $0.value.until > t }
    }

    // MARK: What the view shows

    /// The snapshot's groups, plus rows stopped a moment ago (where the scan no longer has them).
    public var groups: [MemoryGroup] {
        guard let snapshot else { return [] }
        if simulated != nil { return snapshot.groups }
        var groups = snapshot.groups
        for (id, ghost) in ghosts where !groups.contains(where: { $0.items.contains { $0.id == id } }) {
            if let index = groups.firstIndex(where: { $0.kind == ghost.item.group }) {
                groups[index].items.append(ghost.item)
            } else {
                groups.append(MemoryGroup(kind: ghost.item.group, items: [ghost.item]))
                groups.sort { MemoryGroupKind.allCases.firstIndex(of: $0.kind)! < MemoryGroupKind.allCases.firstIndex(of: $1.kind)! }
            }
        }
        return groups
    }

    public func stopState(for id: String) -> StopState? {
        (simulated ?? live).stopStates[id]
    }

    // MARK: Stop

    public func stop(_ item: MemoryItem) {
        run(item, force: false)
    }

    public func forceStop(_ item: MemoryItem) {
        run(item, force: true)
    }

    private func run(_ item: MemoryItem, force: Bool) {
        guard simulated == nil, let target = item.target, live.stopStates[item.id] != .stopping else { return }
        live.stopStates[item.id] = .stopping
        Task { [weak self] in
            guard let self else { return }
            let outcome = force ? await stopper.forceStop(target) : await stopper.stop(target)
            switch outcome {
            case .stopped, .gone:
                live.stopStates[item.id] = .stopped(freedBytes: item.bytes)
                ghosts[item.id] = (item, now().addingTimeInterval(Self.ghostDuration))
            case .notResponding:
                live.stopStates[item.id] = .notResponding
            }
            await scanOnce()
        }
    }

    // MARK: Cheatcodes

    public func simulate(_ presentation: MemoryPresentation) {
        simulated = presentation
    }

    public func resumeLive() {
        simulated = nil
    }
}
