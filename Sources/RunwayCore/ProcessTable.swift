import Foundation
import Darwin

/// One process of the user, as the table sees it. `startTime` doubles as the pid-reuse guard.
public struct ProcessRow: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    /// `pbi_start_tvsec` and `pbi_start_tvusec` as microseconds since the epoch.
    public var startTime: UInt64
    /// Executable file name, falling back to the kernel's 16-character command name.
    public var name: String
    public var path: String
    /// `ri_phys_footprint`: Activity Monitor's Memory column, never RSS.
    public var footprint: UInt64
    /// User + system CPU time in seconds, since the process started.
    public var cpuSeconds: Double

    public init(pid: Int32, ppid: Int32, pgid: Int32 = 0, startTime: UInt64 = 0, name: String, path: String = "",
                footprint: UInt64 = 0, cpuSeconds: Double = 0) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.startTime = startTime
        self.name = name
        self.path = path
        self.footprint = footprint
        self.cpuSeconds = cpuSeconds
    }
}

/// Where the scanner gets processes from. The cheap table comes in one call; the rest is asked
/// lazily, for candidates only. A protocol so the grouping logic runs on fakes.
public protocol ProcessSource: Sendable {
    func processes() -> [ProcessRow]
    func cwd(of pid: Int32) -> String?
    /// argv without the exec path.
    func arguments(of pid: Int32) -> [String]
    /// TCP ports in LISTEN state, unsorted.
    func listeningPorts(of pid: Int32) -> [Int]
    /// The app responsible for this process, nil when the system cannot say.
    func responsiblePid(for pid: Int32) -> Int32?
}

/// libproc / sysctl, unprivileged: only processes of the current user are readable.
public struct LibprocSource: ProcessSource {
    public init() {}

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// Private but stable since 10.14 (Activity Monitor uses it). Missing symbol: callers climb ppid.
    private static let responsible: ResponsibleFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(s, to: ResponsibleFn.self)
    }()

    private static let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()

    public func processes() -> [ProcessRow] {
        let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 64)
        let r = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard r > 0 else { return [] }
        let uid = getuid()
        var rows: [ProcessRow] = []
        rows.reserveCapacity(Int(r) / 4)
        for pid in pids.prefix(Int(r) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard let row = Self.row(pid, onlyUid: uid) else { continue }
            rows.append(row)
        }
        return rows
    }

    /// One process, nil when it is gone or not ours. Used by the stopper to re-check a target.
    public func row(pid: Int32) -> ProcessRow? { Self.row(pid, onlyUid: getuid()) }

    /// Zombies still have a row; the stopper treats them as gone.
    func isZombie(pid: Int32) -> Bool {
        var bi = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return true }
        return bi.pbi_status == UInt32(SZOMB)
    }

    private static func row(_ pid: pid_t, onlyUid uid: uid_t) -> ProcessRow? {
        var bi = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              bi.pbi_uid == uid, bi.pbi_status != UInt32(SZOMB) else { return nil }
        var ri = rusage_info_v4()
        let rr = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rr == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        var name = (path as NSString).lastPathComponent
        if name.isEmpty {
            name = withUnsafePointer(to: &bi.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }
        }
        let cpu = Double(ri.ri_user_time &+ ri.ri_system_time) * timebase / 1e9
        return ProcessRow(pid: pid, ppid: Int32(bitPattern: bi.pbi_ppid), pgid: Int32(bitPattern: bi.pbi_pgid),
                          startTime: bi.pbi_start_tvsec * 1_000_000 + bi.pbi_start_tvusec, name: name, path: path,
                          footprint: ri.ri_phys_footprint, cpuSeconds: cpu)
    }

    public func cwd(of pid: Int32) -> String? {
        var v = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        let s = withUnsafePointer(to: &v.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return s.isEmpty ? nil : s
    }

    public func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        var argc: Int32 = 0
        memcpy(&argc, buf, 4)
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }  // exec path
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        var cur: [UInt8] = []
        while i < size && out.count < Int(argc) {
            if buf[i] == 0 { out.append(String(decoding: cur, as: UTF8.self)); cur = [] } else { cur.append(buf[i]) }
            i += 1
        }
        return Array(out.dropFirst())
    }

    public func listeningPorts(of pid: Int32) -> [Int] {
        let n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard n > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(n) / stride + 8)
        let r = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard r > 0 else { return [] }
        var ports: [Int] = []
        for f in fds.prefix(Int(r) / stride) where f.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            if proc_pidfdinfo(pid, f.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
               si.psi.soi_kind == Int32(SOCKINFO_TCP), si.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) {
                ports.append(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))))
            }
        }
        return ports
    }

    public func responsiblePid(for pid: Int32) -> Int32? {
        guard let f = Self.responsible else { return nil }
        let r = f(pid)
        return r > 0 ? r : nil
    }
}
