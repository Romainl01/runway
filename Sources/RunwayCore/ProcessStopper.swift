import Foundation
import AppKit
import Darwin

/// Stops what a Memory row points at. Always re-checks pid + start time first, and never touches
/// pid ≤ 1, Runway itself or the process group Runway runs in.
public struct ProcessStopper: MemoryStopping {
    public static let grace: TimeInterval = 3
    public static let simulatorGrace: TimeInterval = 10
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "-zsh", "-bash"]

    public init() {}

    public func stop(_ target: MemoryTarget) async -> StopOutcome { await run(target, force: false) }
    public func forceStop(_ target: MemoryTarget) async -> StopOutcome { await run(target, force: true) }

    private func run(_ target: MemoryTarget, force: Bool) async -> StopOutcome {
        switch target {
        case .process(let pid, let start): return await stopProcess(pid, start, force: force)
        case .simulator(let udid): return await shutdownSimulator(udid)
        case .app(let pid, let start): return await quitApp(pid, start, force: force)
        }
    }

    // MARK: Processes

    private func stopProcess(_ pid: Int32, _ start: UInt64, force: Bool) async -> StopOutcome {
        let src = LibprocSource()
        guard pid > 1, pid != getpid(), let root = src.row(pid: pid), root.startTime == start else { return .gone }
        let sig = force ? SIGKILL : SIGTERM
        let me = getpid(), myGroup = getpgrp()

        let leaderIsShell = src.row(pid: root.pgid).map { Self.shells.contains($0.name.lowercased()) } ?? false
        if root.pgid > 1, root.pgid != myGroup, root.pgid != me, !leaderIsShell {
            killpg(root.pgid, sig)
        } else {
            // Shared group (a terminal's): the root first, then everything below it.
            let rows = src.processes()
            let children = Dictionary(grouping: rows, by: \.ppid)
            var targets: [Int32] = [], stack = [pid], seen: Set<Int32> = []
            while let p = stack.popLast() {
                guard seen.insert(p).inserted else { continue }
                targets.append(p)
                stack += (children[p] ?? []).map(\.pid)
            }
            for p in targets where p > 1 && p != me { kill(p, sig) }
        }
        return await waitUntil(Self.grace) { !Self.isAlive(src, pid, start) } ? .stopped : .notResponding
    }

    private static func isAlive(_ src: LibprocSource, _ pid: Int32, _ start: UInt64) -> Bool {
        guard let r = src.row(pid: pid), r.startTime == start else { return false }
        return !src.isZombie(pid: pid)
    }

    // MARK: Simulators

    private func shutdownSimulator(_ udid: String) async -> StopOutcome {
        let src = LibprocSource()
        @Sendable func booted() -> Bool {
            src.processes().contains { $0.name == "launchd_sim" && SystemMemoryScanner.udid(in: src.arguments(of: $0.pid)) == udid }
        }
        guard booted() else { return .gone }
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["simctl", "shutdown", udid]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
        }.value
        return await waitUntil(Self.simulatorGrace) { !booted() } ? .stopped : .notResponding
    }

    // MARK: Apps

    private func quitApp(_ pid: Int32, _ start: UInt64, force: Bool) async -> StopOutcome {
        let src = LibprocSource()
        guard pid > 1, pid != getpid(), let row = src.row(pid: pid), row.startTime == start else { return .gone }
        let asked = await MainActor.run { () -> Bool in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return force ? app.forceTerminate() : app.terminate()
        }
        if !asked && !Self.isAlive(src, pid, start) { return .stopped }
        return await waitUntil(Self.grace) { !Self.isAlive(src, pid, start) } ? .stopped : .notResponding
    }

    // MARK: Polling

    private func waitUntil(_ seconds: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
