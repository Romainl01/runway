import Foundation

/// Builds the Memory tab's snapshot from libproc, `~/.claude/sessions` and the simulator folders.
/// Every pid lands in at most one item; rules run in order: simulators, servers, Claude Code, apps.
/// Scans are serialized (CPU history for the idle signal lives here) and run off the main actor.
public final class SystemMemoryScanner: MemoryScanning, @unchecked Sendable {
    private let source: ProcessSource
    private let home: String
    private let ownPid: Int32
    private let lock = NSLock()

    // Caches, guarded by `lock`.
    private var deviceNames: [String: String] = [:]
    private var bundleNames: [String: String] = [:]
    private var projectCache: [String: (dir: String, name: String)] = [:]
    private var titleCache: [String: (modified: Date, size: Int, title: String?)] = [:]
    private var simActivity: [String: SimActivity] = [:]

    private struct SimActivity {
        var cpu: Double
        var at: Date
        /// Start of the current stretch under the idle threshold.
        var quietSince: Date?
    }

    public static let idleCPUFraction = 0.02
    public static let simulatorIdleAfter: TimeInterval = 30 * 60
    public static let claudeIdleAfter: TimeInterval = 2 * 60 * 60
    public static let minimumAppBytes: UInt64 = 150 * 1_048_576
    public static let maximumApps = 6

    public convenience init() {
        self.init(source: LibprocSource(), homeDirectory: NSHomeDirectory(), ownPid: getpid())
    }

    init(source: ProcessSource, homeDirectory: String, ownPid: Int32) {
        self.source = source
        self.home = homeDirectory
        self.ownPid = ownPid
    }

    public func scan(now: Date) async -> MemorySnapshot {
        await Task.detached(priority: .utility) { [self] in scanSync(now: now) }.value
    }

    func scanSync(now: Date) -> MemorySnapshot {
        let groups = self.groups(now: now)
        return MemorySnapshot(usedBytes: SystemMemory.usedBytes(), totalBytes: SystemMemory.totalBytes,
                              pressure: SystemMemory.pressure(), groups: groups, scannedAt: now)
    }

    func groups(now: Date) -> [MemoryGroup] {
        lock.withLock {
            let ctx = Context(source: source, rows: source.processes())
            let all = [
                (MemoryGroupKind.simulators, simulatorItems(ctx, now: now)),
                (.servers, serverItems(ctx)),
                (.claude, claudeItems(ctx, now: now)),
                (.apps, appItems(ctx)),
            ]
            return all.compactMap { kind, items in
                items.isEmpty ? nil : MemoryGroup(kind: kind, items: items.sorted { $0.bytes > $1.bytes })
            }
        }
    }

    // MARK: Per-scan state

    private final class Context {
        let source: ProcessSource
        let byPid: [Int32: ProcessRow]
        let children: [Int32: [Int32]]
        var assigned: Set<Int32> = []
        var portCache: [Int32: [Int]] = [:]

        init(source: ProcessSource, rows: [ProcessRow]) {
            self.source = source
            byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            children = Dictionary(grouping: rows, by: \.ppid).mapValues { $0.map(\.pid) }
        }

        var rows: [ProcessRow] { Array(byPid.values) }

        /// Root and descendants not yet taken by an earlier rule.
        func subtree(_ root: Int32) -> [ProcessRow] {
            var out: [ProcessRow] = []
            var stack = [root]
            var seen: Set<Int32> = []
            while let p = stack.popLast() {
                guard seen.insert(p).inserted, !assigned.contains(p), let row = byPid[p] else { continue }
                out.append(row)
                stack += children[p] ?? []
            }
            return out
        }

        func ports(_ pid: Int32) -> [Int] {
            if let c = portCache[pid] { return c }
            let p = source.listeningPorts(of: pid)
            portCache[pid] = p
            return p
        }

        func claim(_ rows: [ProcessRow]) { assigned.formUnion(rows.map(\.pid)) }
    }

    // MARK: 1. Simulators

    private func simulatorItems(_ ctx: Context, now: Date) -> [MemoryItem] {
        var items: [MemoryItem] = []
        var live: Set<String> = []
        for launchd in ctx.rows where launchd.name == "launchd_sim" && !ctx.assigned.contains(launchd.pid) {
            guard let udid = Self.udid(in: ctx.source.arguments(of: launchd.pid)) else { continue }
            let tree = ctx.subtree(launchd.pid)
            ctx.claim(tree)
            live.insert(udid)

            // The app on screen: the largest .app under the device's Bundle/Application.
            var perApp: [String: UInt64] = [:]
            let marker = "/Devices/\(udid)/data/Containers/Bundle/Application/"
            for p in tree {
                guard let r = p.path.range(of: marker), let app = Self.bundlePath(in: p.path, from: r.upperBound) else { continue }
                perApp[app, default: 0] += p.footprint
            }
            let appName = perApp.max { $0.value < $1.value }.map { bundleName($0.key) }

            let reason: MemoryReason?
            if appName == nil {
                reason = .noAppOpen
                simActivity[udid] = nil
            } else {
                reason = idleReason(udid: udid, cpu: tree.reduce(0) { $0 + $1.cpuSeconds }, now: now)
            }
            items.append(MemoryItem(
                id: udid, group: .simulators, name: deviceName(udid), context: appName,
                bytes: tree.reduce(0) { $0 + $1.footprint }, reason: reason,
                target: .simulator(udid: udid)))
        }
        simActivity = simActivity.filter { live.contains($0.key) }
        return items
    }

    private func idleReason(udid: String, cpu: Double, now: Date) -> MemoryReason? {
        guard var a = simActivity[udid] else {
            simActivity[udid] = SimActivity(cpu: cpu, at: now, quietSince: nil)
            return nil
        }
        let dt = now.timeIntervalSince(a.at)
        if dt > 0 {
            let fraction = (cpu - a.cpu) / dt
            if cpu < a.cpu { a.quietSince = nil }  // processes came and went: no verdict
            else if fraction < Self.idleCPUFraction { a.quietSince = a.quietSince ?? a.at }
            else { a.quietSince = nil }
            a.cpu = cpu
            a.at = now
        }
        simActivity[udid] = a
        if let since = a.quietSince, now.timeIntervalSince(since) >= Self.simulatorIdleAfter { return .idle(since: since) }
        return nil
    }

    static func udid(in argv: [String]) -> String? {
        for a in argv {
            guard let r = a.range(of: "/CoreSimulator/Devices/") else { continue }
            let id = a[r.upperBound...].prefix { $0 != "/" }
            if !id.isEmpty { return String(id) }
        }
        return nil
    }

    private func deviceName(_ udid: String) -> String {
        if let n = deviceNames[udid] { return n }
        let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/device.plist")
        if let d = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
           let name = plist["name"] as? String, !name.isEmpty {
            deviceNames[udid] = name
            return name
        }
        return "iOS Simulator"
    }

    // MARK: 2. Servers

    private static let packageManagers: Set<String> = ["npm", "npx", "pnpm", "yarn"]

    private static func isRuntime(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == "node" || n == "bun" || n == "deno" || n.hasPrefix("python")
    }

    private static func isInterpreter(_ name: String) -> Bool {
        isRuntime(name) || packageManagers.contains(name.lowercased())
    }

    private func serverItems(_ ctx: Context) -> [MemoryItem] {
        let sessionPids = Set(readSessions().map(\.pid))
        // root pid -> processes that own a listening port
        var roots: [Int32: [ProcessRow]] = [:]
        for row in ctx.rows.sorted(by: { $0.pid < $1.pid }) where Self.isRuntime(row.name) && !ctx.assigned.contains(row.pid)
            && !sessionPids.contains(row.pid) && !ctx.ports(row.pid).isEmpty {
            let dir = projectDir(of: row.pid, ctx)
            var root = row
            while let parent = ctx.byPid[root.ppid], parent.pid > 1, !ctx.assigned.contains(parent.pid),
                  !sessionPids.contains(parent.pid), Self.isInterpreter(parent.name),
                  projectDir(of: parent.pid, ctx) == dir {
                root = parent
            }
            roots[root.pid, default: []].append(row)
        }

        var items: [MemoryItem] = []
        var meta: [(id: String, project: String, command: String?, start: UInt64)] = []
        for (rootPid, owners) in roots.sorted(by: { $0.key < $1.key }) {
            guard !ctx.assigned.contains(rootPid), let root = ctx.byPid[rootPid] else { continue }
            let tree = ctx.subtree(rootPid)
            ctx.claim(tree)
            let ports = Set(tree.flatMap { ctx.ports($0.pid) }).sorted()
            let projectInfo = project(of: root.pid, ctx) ?? owners.lazy.compactMap { self.project(of: $0.pid, ctx) }.first
            let projectName = projectInfo?.name ?? root.name
            let command = Self.readableCommand(
                ([root] + owners.sorted { $0.footprint > $1.footprint }).map { ctx.source.arguments(of: $0.pid) })
            let id = "server-\(root.pid)-\(root.startTime)"
            items.append(MemoryItem(
                id: id, group: .servers, name: projectName, context: command, ports: ports,
                bytes: tree.reduce(0) { $0 + $1.footprint }, reason: root.ppid == 1 ? .orphan : nil,
                target: .process(pid: root.pid, startTime: root.startTime)))
            meta.append((id, projectName, command, root.startTime))
        }

        // The older of two servers running the same command for the same project.
        let byKey = Dictionary(grouping: meta.filter { $0.command != nil }, by: { "\($0.project)\u{0}\($0.command!)" })
        for (_, same) in byKey where same.count > 1 {
            let newest = same.max { $0.start < $1.start }!
            for m in same where m.id != newest.id {
                if let i = items.firstIndex(where: { $0.id == m.id }), items[i].reason == nil { items[i].reason = .duplicate }
            }
        }
        return items
    }

    /// Nearest directory with a package.json (below $HOME), else the cwd itself.
    private func project(of pid: Int32, _ ctx: Context) -> (dir: String, name: String)? {
        guard let cwd = ctx.source.cwd(of: pid) else { return nil }
        if let c = projectCache[cwd] { return c }
        var dir = cwd
        var result: (dir: String, name: String) = (cwd, (cwd as NSString).lastPathComponent)
        while dir.count > 1, dir != home {
            let pkg = (dir as NSString).appendingPathComponent("package.json")
            if let d = FileManager.default.contents(atPath: pkg) {
                let name = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["name"] as? String
                result = (dir, (name?.isEmpty == false ? name! : (dir as NSString).lastPathComponent))
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        projectCache[cwd] = result
        return result
    }

    private func projectDir(of pid: Int32, _ ctx: Context) -> String? { project(of: pid, ctx)?.dir }

    private static let toolAliases = ["@expo/cli": "expo", "@react-native-community/cli": "react-native", "@angular/cli": "ng"]
    private static let knownTools: Set<String> = [
        "expo", "next", "vite", "nuxt", "astro", "remix", "webpack", "webpack-dev-server", "metro", "storybook", "tsx",
        "nodemon", "ts-node", "ts-node-dev", "wrangler", "uvicorn", "flask", "gunicorn", "fastapi", "http-server", "serve", "ng",
        "vue-cli-service", "react-scripts", "parcel", "turbo", "nx", "gatsby", "vitepress", "docusaurus", "json-server",
        "live-server", "bun", "deno", "npm", "npx", "pnpm", "yarn", "react-native",
    ]

    /// `expo start`, `next dev`, `vite`, `npm run dev`: the tool and its next non-flag word.
    /// Tries each argv in order for a `.bin/<tool>`, a `node_modules/<pkg>` or a known tool word.
    static func readableCommand(_ argvs: [[String]]) -> String? {
        let found = argvs.compactMap { command(in: $0) }
        if let best = found.first(where: { !packageManagers.contains($0.tool) }) ?? found.first { return best.text }
        // Fallback: the script's basename.
        for argv in argvs {
            if let script = argv.first(where: { !$0.hasPrefix("-") }) { return (script as NSString).lastPathComponent }
        }
        return nil
    }

    private static func command(in argv: [String]) -> (tool: String, text: String)? {
        for (i, token) in argv.enumerated() {
            var tool: String?
            if token == "-m", i + 1 < argv.count { tool = argv[i + 1] }
            else if token.hasPrefix("-") { continue }
            else { tool = toolName(in: token) }
            guard let t = tool else { continue }
            let rest = argv.dropFirst(token == "-m" ? i + 2 : i + 1)
            var words = rest.filter { !$0.hasPrefix("-") && Int($0) == nil }.prefix(1).map { $0 }
            if packageManagers.contains(t) || t == "bun", words.first == "run" {
                words = [rest.filter { !$0.hasPrefix("-") }.dropFirst().first].compactMap { $0 }.map { "run \($0)" }
            }
            return (t, ([t] + words).joined(separator: " "))
        }
        return nil
    }

    private static func toolName(in token: String) -> String? {
        let comps = token.split(separator: "/").map(String.init)
        if let i = comps.lastIndex(of: "node_modules"), i + 1 < comps.count {
            var pkg = comps[i + 1]
            if pkg == ".bin", i + 2 < comps.count { return stripExtension(comps[i + 2]) }
            if pkg.hasPrefix("@"), i + 2 < comps.count {
                pkg += "/" + comps[i + 2]
                return toolAliases[pkg] ?? comps[i + 2]
            }
            return pkg
        }
        let base = stripExtension(comps.last ?? token)
        return knownTools.contains(base) ? base : nil
    }

    private static func stripExtension(_ s: String) -> String {
        ["js", "mjs", "cjs", "py", "ts"].contains((s as NSString).pathExtension) ? (s as NSString).deletingPathExtension : s
    }

    // MARK: 3. Claude Code

    struct ClaudeSession {
        var pid: Int32
        var sessionId: String
        var cwd: String
        var name: String?
        var status: String
        var statusUpdatedAt: Date?
        var startedAt: Date?
    }

    private func readSessions() -> [ClaudeSession] {
        let dir = (home as NSString).appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [ClaudeSession] = []
        for f in files where f.hasSuffix(".json") && Int32((f as NSString).deletingPathExtension) != nil {
            guard let d = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(f)),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = (j["pid"] as? NSNumber)?.int32Value, let id = j["sessionId"] as? String,
                  (j["kind"] as? String) == "interactive" else { continue }
            let ms = { (k: String) in (j[k] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
            out.append(ClaudeSession(pid: pid, sessionId: id, cwd: j["cwd"] as? String ?? "", name: j["name"] as? String,
                                     status: j["status"] as? String ?? "", statusUpdatedAt: ms("statusUpdatedAt"),
                                     startedAt: ms("startedAt")))
        }
        return out
    }

    private func claudeItems(_ ctx: Context, now: Date) -> [MemoryItem] {
        var items: [MemoryItem] = []
        for s in readSessions().sorted(by: { $0.pid < $1.pid }) {
            // A reused pid started long after the session file was written is not that session.
            guard let root = ctx.byPid[s.pid], !ctx.assigned.contains(s.pid),
                  s.startedAt.map({ Double(root.startTime) / 1e6 <= $0.timeIntervalSince1970 + 300 }) ?? true else { continue }
            let tree = ctx.subtree(s.pid)
            ctx.claim(tree)
            var reason: MemoryReason?
            if s.status == "idle", let since = s.statusUpdatedAt, now.timeIntervalSince(since) > Self.claudeIdleAfter {
                reason = .noMessage(since: since)
            }
            let title = conversationTitle(cwd: s.cwd, sessionId: s.sessionId)
                ?? (s.name?.isEmpty == false ? s.name : nil) ?? "Claude Code"
            items.append(MemoryItem(
                id: s.sessionId, group: .claude, name: title,
                context: s.cwd.isEmpty ? nil : (s.cwd as NSString).lastPathComponent,
                bytes: tree.reduce(0) { $0 + $1.footprint }, reason: reason, isBusy: s.status == "busy",
                target: .process(pid: root.pid, startTime: root.startTime)))
        }
        return items
    }

    /// Last `"aiTitle":"…"` in the last 256 KB of the conversation file. Never reads the whole file.
    private func conversationTitle(cwd: String, sessionId: String) -> String? {
        let folder = String(cwd.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
        let path = (home as NSString).appendingPathComponent(".claude/projects/\(folder)/\(sessionId).jsonl")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue, let modified = attrs[.modificationDate] as? Date else { return nil }
        if let c = titleCache[path], c.size == size, c.modified == modified { return c.title }
        let title = Self.lastTitle(inTailOf: path, size: size)
        titleCache[path] = (modified, size, title)
        return title
    }

    static func lastTitle(inTailOf path: String, size: Int, tailBytes: Int = 256 * 1024) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(max(0, size - tailBytes)))
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "\"aiTitle\":\"", options: .backwards) else { return nil }
        var raw = ""
        var escaped = false
        for ch in text[key.upperBound...] {
            if escaped { raw.append(ch); escaped = false }
            else if ch == "\\" { raw.append(ch); escaped = true }
            else if ch == "\"" { break }
            else { raw.append(ch) }
        }
        guard let d = "\"\(raw)\"".data(using: .utf8),
              let s = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) as? String else { return raw.isEmpty ? nil : raw }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: 4. Apps

    private func appItems(_ ctx: Context) -> [MemoryItem] {
        var own: Set<Int32> = []
        var stack = [ownPid]
        while let p = stack.popLast() { if own.insert(p).inserted { stack += ctx.children[p] ?? [] } }

        var perResponsible: [Int32: (bundle: String, rows: [ProcessRow])] = [:]
        for row in ctx.rows where !ctx.assigned.contains(row.pid) && !own.contains(row.pid) {
            guard let (rpid, bundle) = responsibleApp(for: row, ctx), !own.contains(rpid) else { continue }
            perResponsible[rpid, default: (bundle, [])].rows.append(row)
        }

        var items: [MemoryItem] = []
        for (rpid, group) in perResponsible {
            let bytes = group.rows.reduce(0) { $0 + $1.footprint }
            guard bytes >= Self.minimumAppBytes, let main = ctx.byPid[rpid] else { continue }
            items.append(MemoryItem(id: group.bundle, group: .apps, name: bundleName(group.bundle), bytes: bytes,
                                    target: .app(pid: main.pid, startTime: main.startTime)))
        }
        // Two instances of one bundle would share an id: keep ids unique by pid.
        var seen: Set<String> = []
        items = items.sorted { $0.bytes > $1.bytes }.map {
            var i = $0
            if !seen.insert(i.id).inserted, case .app(let pid, _)? = i.target { i.id += "#\(pid)" }
            return i
        }
        return Array(items.prefix(Self.maximumApps))
    }

    /// Pid and bundle path of the app a process belongs to.
    private func responsibleApp(for row: ProcessRow, _ ctx: Context) -> (Int32, String)? {
        if let r = ctx.source.responsiblePid(for: row.pid), let rrow = ctx.byPid[r], let b = Self.appBundle(of: rrow.path) {
            return (r, b)
        }
        // Fallback: climb ppid to the first executable inside an .app.
        var cur: ProcessRow? = row
        var hops = 0
        while let c = cur, hops < 64 {
            if let b = Self.appBundle(of: c.path) { return (c.pid, b) }
            cur = ctx.byPid[c.ppid]
            hops += 1
        }
        return nil
    }

    /// The outermost `.app` of an executable path, nil for system internals.
    static func appBundle(of exe: String) -> String? {
        if exe.hasPrefix("/System/Library/") { return nil }
        return bundlePath(in: exe, from: exe.startIndex)
    }

    /// `…/X.app` for the first `.app` component at or after `start`.
    static func bundlePath(in path: String, from start: String.Index) -> String? {
        guard let r = path.range(of: ".app/", range: start..<path.endIndex) ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    private func bundleName(_ bundle: String) -> String {
        if let n = bundleNames[bundle] { return n }
        var name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        for rel in ["Contents/Info.plist", "Info.plist"] {
            let p = (bundle as NSString).appendingPathComponent(rel)
            if let d = FileManager.default.contents(atPath: p),
               let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                let n = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (plist["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let n { name = n }
                break
            }
        }
        bundleNames[bundle] = name
        return name
    }
}
