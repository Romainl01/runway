import Foundation
import Testing
@testable import RunwayCore

private let MB: UInt64 = 1_048_576

struct FakeSource: ProcessSource {
    var rows: [ProcessRow] = []
    var cwds: [Int32: String] = [:]
    var argv: [Int32: [String]] = [:]
    var ports: [Int32: [Int]] = [:]
    var responsible: [Int32: Int32] = [:]

    func processes() -> [ProcessRow] { rows }
    func cwd(of pid: Int32) -> String? { cwds[pid] }
    func arguments(of pid: Int32) -> [String] { argv[pid] ?? [] }
    func listeningPorts(of pid: Int32) -> [Int] { ports[pid] ?? [] }
    func responsiblePid(for pid: Int32) -> Int32? { responsible[pid] }
}

/// A fake whose table changes between scans.
final class MutableSource: ProcessSource, @unchecked Sendable {
    var value = FakeSource()
    func processes() -> [ProcessRow] { value.rows }
    func cwd(of pid: Int32) -> String? { value.cwd(of: pid) }
    func arguments(of pid: Int32) -> [String] { value.arguments(of: pid) }
    func listeningPorts(of pid: Int32) -> [Int] { value.listeningPorts(of: pid) }
    func responsiblePid(for pid: Int32) -> Int32? { value.responsiblePid(for: pid) }
}

private func row(_ pid: Int32, _ ppid: Int32, _ name: String, mb: UInt64 = 10, path: String? = nil, start: UInt64 = 1, cpu: Double = 0) -> ProcessRow {
    ProcessRow(pid: pid, ppid: ppid, pgid: pid, startTime: start, name: name, path: path ?? "/usr/bin/\(name)",
               footprint: mb * MB, cpuSeconds: cpu)
}

private func tempHome() throws -> String {
    let dir = NSTemporaryDirectory() + "runway-scan-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func scanner(_ s: FakeSource, home: String, own: Int32 = 99_999) -> SystemMemoryScanner {
    SystemMemoryScanner(source: s, homeDirectory: home, ownPid: own)
}

private func items(_ groups: [MemoryGroup], _ kind: MemoryGroupKind) -> [MemoryItem] {
    groups.first { $0.kind == kind }?.items ?? []
}

@Suite("MemoryScanner grouping")
struct MemoryScannerTests {
    @Test func simulatorSumsItsSubtreeAndNamesTheApp() throws {
        let home = try tempHome()
        let udid = "AAAA-1111"
        let devDir = home + "/Library/Developer/CoreSimulator/Devices/\(udid)"
        try FileManager.default.createDirectory(atPath: devDir, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["name": "iPhone 17 Pro"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: devDir + "/device.plist"))
        let appExe = "\(devDir)/data/Containers/Bundle/Application/G1/Oly.app/Oly"
        var s = FakeSource()
        s.rows = [
            row(100, 1, "launchd_sim", mb: 5),
            row(101, 100, "backboardd", mb: 100),
            row(102, 101, "Oly", mb: 800, path: appExe),
            row(103, 102, "helper", mb: 50),
            row(500, 1, "Simulator", mb: 1400),
        ]
        s.argv[100] = ["\(devDir)/data/var/run/launchd_bootstrap.plist"]
        let g = scanner(s, home: home).groups(now: Date())
        let sim = try #require(items(g, .simulators).first)
        #expect(sim.id == udid)
        #expect(sim.name == "iPhone 17 Pro")
        #expect(sim.context == "Oly")
        #expect(sim.bytes == 955 * MB)
        #expect(sim.reason == nil)
        #expect(sim.target == .simulator(udid: udid))
    }

    @Test func simulatorWithoutAppIsFlagged() throws {
        let home = try tempHome()
        var s = FakeSource()
        s.rows = [row(100, 1, "launchd_sim"), row(101, 100, "backboardd", mb: 100)]
        s.argv[100] = ["/x/CoreSimulator/Devices/BBBB/data/var/run/launchd_bootstrap.plist"]
        let sim = try #require(items(scanner(s, home: home).groups(now: Date()), .simulators).first)
        #expect(sim.context == nil)
        #expect(sim.reason == .noAppOpen)
    }

    @Test func simulatorIdleAfterThirtyQuietMinutes() throws {
        let home = try tempHome()
        let appExe = "/x/CoreSimulator/Devices/CCCC/data/Containers/Bundle/Application/G/Oly.app/Oly"
        let box = MutableSource()
        box.value.argv[100] = ["/x/CoreSimulator/Devices/CCCC/data/var/run/launchd_bootstrap.plist"]
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let sc = SystemMemoryScanner(source: box, homeDirectory: home, ownPid: 99_999)
        func at(_ minutes: Double, cpu: Double) -> [MemoryGroup] {
            box.value.rows = [row(100, 1, "launchd_sim", cpu: 0), row(101, 100, "Oly", path: appExe, cpu: cpu)]
            return sc.groups(now: t0.addingTimeInterval(minutes * 60))
        }
        _ = at(0, cpu: 0)
        #expect(items(at(10, cpu: 1), .simulators).first?.reason == nil)
        #expect(items(at(40, cpu: 2), .simulators).first?.reason == .idle(since: t0))
        // Busy again: the clock restarts.
        #expect(items(at(41, cpu: 200), .simulators).first?.reason == nil)
    }

    @Test func serverProjectPortsCommandAndOrphan() throws {
        let home = try tempHome()
        let proj = home + "/code/my-app"
        let sub = proj + "/ios"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try Data(#"{"name":"my-app-pkg"}"#.utf8).write(to: URL(fileURLWithPath: proj + "/package.json"))
        var s = FakeSource()
        s.rows = [
            row(10, 1, "node", mb: 50),   // npm wrapper, orphaned
            row(11, 10, "node", mb: 900), // expo
            row(12, 11, "node", mb: 100), // child with another port
            row(20, 1, "node", mb: 70),   // MCP server, no port
            row(1, 0, "launchd"),
        ]
        s.cwds = [10: proj, 11: proj, 12: sub]
        s.argv[10] = ["/usr/lib/node_modules/npm/bin/npm-cli.js", "run", "start"]
        s.argv[11] = [proj + "/node_modules/.bin/expo", "start", "--dev-client", "--port", "8084"]
        s.ports = [11: [8084], 12: [8097, 8084]]
        let g = scanner(s, home: home).groups(now: Date())
        let servers = items(g, .servers)
        #expect(servers.count == 1)
        let srv = try #require(servers.first)
        #expect(srv.name == "my-app-pkg")
        #expect(srv.context == "expo start")
        #expect(srv.ports == [8084, 8097])
        #expect(srv.bytes == 1050 * MB)
        #expect(srv.reason == .orphan)
        #expect(srv.target == .process(pid: 10, startTime: 1))
    }

    @Test func olderDuplicateServerIsFlagged() throws {
        let home = try tempHome()
        let proj = home + "/code/web"
        try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        var s = FakeSource()
        s.rows = [row(10, 5, "node", start: 100), row(20, 5, "node", start: 200), row(5, 1, "zsh")]
        s.cwds = [10: proj, 20: proj]
        for p: Int32 in [10, 20] {
            s.argv[p] = [proj + "/node_modules/next/dist/bin/next", "dev"]
            s.ports[p] = [3000 + Int(p)]
        }
        let servers = items(scanner(s, home: home).groups(now: Date()), .servers)
        #expect(servers.count == 2)
        #expect(servers.first { $0.id.hasPrefix("server-10") }?.reason == .duplicate)
        #expect(servers.first { $0.id.hasPrefix("server-20") }?.reason == nil)
        #expect(servers.allSatisfy { $0.name == "web" && $0.context == "next dev" })
    }

    @Test func readableCommands() {
        typealias S = SystemMemoryScanner
        #expect(S.readableCommand([["/p/node_modules/vite/bin/vite.js"]]) == "vite")
        #expect(S.readableCommand([["/p/node_modules/@expo/cli/build/bin/cli", "start"]]) == "expo start")
        #expect(S.readableCommand([["/usr/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"]]) == "npm run dev")
        #expect(S.readableCommand([["-m", "uvicorn", "app:app", "--port", "8000"]]) == "uvicorn app:app")
        #expect(S.readableCommand([["server.js"]]) == "server.js")
    }

    @Test func claudeTitleFromJsonlTailAndExclusivity() throws {
        let home = try tempHome()
        let cwd = "/Users/me/Desktop/app/my.app"
        let sid = "sess-1"
        try FileManager.default.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        let started = Date().timeIntervalSince1970 * 1000
        let statusAt = (Date().timeIntervalSince1970 - 3 * 3600) * 1000
        let json = #"{"pid":300,"sessionId":"sess-1","cwd":"\#(cwd)","kind":"interactive","name":"fallback","status":"idle","startedAt":\#(started),"statusUpdatedAt":\#(statusAt)}"#
        try json.write(toFile: home + "/.claude/sessions/300.json", atomically: true, encoding: .utf8)
        let bg = #"{"pid":301,"sessionId":"bg","cwd":"/x","kind":"bg","status":"idle"}"#
        try bg.write(toFile: home + "/.claude/sessions/301.json", atomically: true, encoding: .utf8)
        // Title only in the old part would be missed; the last one wins; padding pushes the first out of the tail.
        let folder = home + "/.claude/projects/-Users-me-Desktop-app-my-app"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let body = #"{"aiTitle":"Old title"}"# + "\n" + String(repeating: "x", count: 300_000) + "\n"
            + #"{"type":"ai-title","aiTitle":"Fix the \"memory\" tab"}"# + "\n" + #"{"other":1}"#
        try body.write(toFile: folder + "/\(sid).jsonl", atomically: true, encoding: .utf8)

        var s = FakeSource()
        s.rows = [
            row(300, 1, "claude", mb: 400, start: 1),
            row(310, 300, "zsh", mb: 5),
            row(311, 310, "node", mb: 300),  // dev server under claude: belongs to servers
            row(301, 1, "claude", mb: 90),
        ]
        s.cwds = [311: "/tmp/proj"]
        s.argv[311] = ["/tmp/proj/node_modules/.bin/vite"]
        s.ports[311] = [5173]
        let g = scanner(s, home: home).groups(now: Date())
        let claude = try #require(items(g, .claude).first)
        #expect(items(g, .claude).count == 1)
        #expect(claude.id == sid)
        #expect(claude.name == #"Fix the "memory" tab"#)
        #expect(claude.context == "my.app")
        #expect(claude.bytes == 405 * MB)
        #expect(claude.isBusy == false)
        if case .noMessage? = claude.reason {} else { Issue.record("expected noMessage, got \(String(describing: claude.reason))") }
        let all = g.flatMap(\.items)
        #expect(items(g, .servers).first?.bytes == 300 * MB)
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func claudeFallsBackToNameThenDefault() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        for (pid, name) in [(300, #","name":"banned-06""#), (301, "")] {
            let j = #"{"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"/a/b","kind":"interactive","status":"busy"\#(name)}"#
            try j.write(toFile: home + "/.claude/sessions/\(pid).json", atomically: true, encoding: .utf8)
        }
        var s = FakeSource()
        s.rows = [row(300, 1, "claude", mb: 200), row(301, 1, "claude", mb: 100)]
        let c = items(scanner(s, home: home).groups(now: Date()), .claude)
        #expect(c.map(\.name) == ["banned-06", "Claude Code"])
        #expect(c.allSatisfy { $0.isBusy })
    }

    @Test func appsGroupByResponsiblePidAndFilter() throws {
        let home = try tempHome()
        var s = FakeSource()
        s.rows = [
            row(600, 1, "Dia", mb: 400, path: "/Applications/Dia.app/Contents/MacOS/Dia"),
            row(601, 600, "Dia Helper", mb: 800, path: "/Applications/Dia.app/Contents/Frameworks/H.app/Contents/MacOS/H"),
            row(610, 1, "Small", mb: 100, path: "/Applications/Small.app/Contents/MacOS/Small"),
            row(620, 1, "Dock", mb: 900, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
            row(630, 1, "Mine", mb: 900, path: "/Applications/Runway.app/Contents/MacOS/Runway"),
            row(631, 630, "node", mb: 900, path: "/usr/bin/node"),
            row(640, 1, "tool", mb: 300, path: "/usr/bin/tool"),  // child of Dia via responsibility
        ]
        s.responsible = [601: 600, 640: 600]
        let g = scanner(s, home: home, own: 630).groups(now: Date())
        let apps = items(g, .apps)
        #expect(apps.count == 1)
        #expect(apps[0].name == "Dia")
        #expect(apps[0].id == "/Applications/Dia.app")
        #expect(apps[0].bytes == 1500 * MB)
        #expect(apps[0].reason == nil)
        #expect(apps[0].target == .app(pid: 600, startTime: 1))
    }

    @Test func appsFallBackToPpidClimbAndKeepTopSix() throws {
        let home = try tempHome()
        var s = FakeSource()
        for i in 0..<8 {
            let p = Int32(700 + i * 2)
            s.rows.append(row(p, 1, "App\(i)", mb: 200 + UInt64(i) * 10, path: "/Applications/App\(i).app/Contents/MacOS/App\(i)"))
            s.rows.append(row(p + 1, p, "child", mb: 10))
        }
        let apps = items(scanner(s, home: home).groups(now: Date()), .apps)
        #expect(apps.count == 6)
        #expect(apps.first?.name == "App7")
        #expect(apps.map(\.bytes) == apps.map(\.bytes).sorted(by: >))
    }

    @Test func groupOrderAndEmptyGroupsOmitted() throws {
        let home = try tempHome()
        var s = FakeSource()
        s.rows = [row(600, 1, "Dia", mb: 400, path: "/Applications/Dia.app/Contents/MacOS/Dia")]
        #expect(scanner(s, home: home).groups(now: Date()).map(\.kind) == [.apps])
    }

    // MARK: Stopper (only on processes this test spawns)

    @Test func stopperTerminatesASpawnedChild() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        let src = LibprocSource()
        let start = try #require(src.row(pid: p.processIdentifier)).startTime
        let stopper = ProcessStopper()
        let target = MemoryTarget.process(pid: p.processIdentifier, startTime: start)
        #expect(await stopper.stop(.process(pid: p.processIdentifier, startTime: start + 1)) == .gone)
        #expect(p.isRunning)
        #expect(await stopper.stop(target) == .stopped)
        #expect(await stopper.stop(target) == .gone)
    }

    @Test func stopperRefusesPidOneAndItself() async {
        let stopper = ProcessStopper()
        #expect(await stopper.stop(.process(pid: 1, startTime: 0)) == .gone)
        #expect(await stopper.stop(.process(pid: 0, startTime: 0)) == .gone)
        let me = LibprocSource().row(pid: getpid())
        #expect(await stopper.stop(.process(pid: getpid(), startTime: me?.startTime ?? 0)) == .gone)
    }

    @Test func forceStopKillsAProcessThatIgnoresTerm() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "trap '' TERM; while :; do sleep 1; done"]
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        try await Task.sleep(for: .milliseconds(300))
        let start = try #require(LibprocSource().row(pid: p.processIdentifier)).startTime
        let target = MemoryTarget.process(pid: p.processIdentifier, startTime: start)
        let stopper = ProcessStopper()
        #expect(await stopper.stop(target) == .notResponding)
        #expect(await stopper.forceStop(target) == .stopped)
    }

    // MARK: Live

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNWAY_LIVE_SCAN"] == "1"))
    func liveScan() async throws {
        let scanner = SystemMemoryScanner()
        _ = await scanner.scan(now: Date())
        let t0 = Date()
        let snap = await scanner.scan(now: Date())
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        print("LIVE used \(gb(snap.usedBytes)) / \(gb(snap.totalBytes)) pressure=\(snap.pressure) scan=\(ms)ms")
        for g in snap.groups {
            print("[\(g.kind.rawValue)] \(g.items.count)")
            for i in g.items {
                let ports = i.ports.isEmpty ? "" : " ports=\(i.ports)"
                print("  \(i.name) | \(i.context ?? "-") | \(i.bytes / MB) MB | \(i.reason.map { "\($0)" } ?? "-")\(i.isBusy ? " BUSY" : "")\(ports)")
            }
        }
        #expect(!snap.groups.isEmpty)
    }
}
