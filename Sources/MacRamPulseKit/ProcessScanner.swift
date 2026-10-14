import Foundation
import Darwin

// MARK: - Process Scanner (libproc + cross-scan CPU idle tracking)

/// One process observation. `idleSec` is how long this app has seen the process
/// consume (almost) no CPU, measured across successive scans.
struct ProcSample {
    let pid: pid_t
    let ppid: pid_t
    let path: String
    let parentPath: String
    let grandparentPath: String
    let args: String         // node and Codex-started processes (OpenClaw / duplicate detection)
    let cwd: String          // same scope as args (same argv can be different servers)
    let rssMB: Double
    let footprintMB: Double
    let ageSec: Int64
    let idleSec: Double
}

/// Tracks, per process instance, how long it has used (almost) no CPU.
/// Activity is judged per scan interval, so a burst right after a long idle period is seen at once.
struct IdleTracker {
    struct Key: Hashable { let pid: pid_t; let startAbs: UInt64 }
    private struct CPUMark { let cpuSec: Double; let seenAt: TimeInterval; let lastActive: TimeInterval }

    /// A process is "active" if, between two scans, it used more than this share of one core.
    static let idleCpuShare = 0.005
    static let minActivityCpuSec = 0.02

    private var marks: [Key: CPUMark] = [:]

    var trackedCount: Int { marks.count }

    /// First sighting counts as "active now", so idle time only accumulates while we watch.
    mutating func update(key: Key, cpuSec: Double, now: TimeInterval) -> Double {
        var lastActive = now
        if let mark = marks[key] {
            let interval = max(0, now - mark.seenAt)
            let allowance = max(Self.minActivityCpuSec, interval * Self.idleCpuShare)
            if cpuSec - mark.cpuSec <= allowance { lastActive = mark.lastActive }
        }
        marks[key] = CPUMark(cpuSec: cpuSec, seenAt: now, lastActive: lastActive)
        return now - lastActive
    }

    mutating func prune(keeping seen: Set<Key>) {
        marks = marks.filter { seen.contains($0.key) }
    }
}

/// argv parsing for a KERN_PROCARGS2 buffer:
/// [argc:int32][exec path\0][padding \0...][argv0\0][argv1\0]...[env...]
enum ProcArgs {
    static func parse(_ buf: [UInt8], count: Int) -> String {
        let size = min(count, buf.count)
        guard size > MemoryLayout<Int32>.size else { return "" }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var idx = MemoryLayout<Int32>.size
        while idx < size && buf[idx] != 0 { idx += 1 }
        while idx < size && buf[idx] == 0 { idx += 1 }
        var args: [String] = []
        var start = idx
        while idx < size && args.count < argc {
            if buf[idx] == 0 {
                args.append(String(decoding: buf[start..<idx], as: UTF8.self))
                start = idx + 1
            }
            idx += 1
        }
        return args.joined(separator: " ")
    }
}

/// Not thread-safe: call only from SystemMemoryMonitor.scanQueue.
final class ProcessScanner {
    static let minTrackedMB = 5.0
    static let maxPids = 4096
    private typealias Key = IdleTracker.Key

    private var idle = IdleTracker()
    private struct NodeMeta { let args: String; let cwd: String }
    private var nodeMetaCache: [Key: NodeMeta] = [:]
    private let ticksToSec: Double
    private let argMax: Int

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        ticksToSec = Double(tb.numer) / Double(tb.denom) / 1_000_000_000
        var am: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        argMax = sysctl(&mib, 2, &am, &sz, nil, 0) == 0 ? Int(am) : 256 * 1024
    }

    static func isNode(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "node"
    }

    func scan() -> [ProcSample] {
        var pids = [pid_t](repeating: 0, count: Self.maxPids)
        let count = max(0, Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))))
        let now = Date().timeIntervalSince1970
        let myPid = getpid()
        var seen = Set<Key>()
        var pathMemo: [pid_t: String] = [:]
        var ppidMemo: [pid_t: pid_t] = [:]
        var samples: [ProcSample] = []
        samples.reserveCapacity(256)

        for pid in pids.prefix(count) where pid > 0 && pid != myPid {
            var ru = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { continue }
            let rssMB = Double(ru.ri_resident_size) / 1_048_576
            let footprintMB = max(rssMB, Double(ru.ri_phys_footprint) / 1_048_576)
            guard footprintMB >= Self.minTrackedMB || rssMB >= Self.minTrackedMB else { continue }

            let path = Self.path(of: pid, memo: &pathMemo)
            guard !path.isEmpty else { continue }

            var bsd = proc_bsdinfo()
            let hasBsd = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
            let ppid = hasBsd ? pid_t(bsd.pbi_ppid) : 0
            ppidMemo[pid] = ppid
            let ageSec = hasBsd ? Int64(now) - Int64(bsd.pbi_start_tvsec) : 0

            let key = Key(pid: pid, startAbs: ru.ri_proc_start_abstime)
            seen.insert(key)
            let cpuSec = Double(ru.ri_user_time + ru.ri_system_time) * ticksToSec
            let idleSec = idle.update(key: key, cpuSec: cpuSec, now: now)
            let parentPath = ppid > 1 ? Self.path(of: ppid, memo: &pathMemo) : ""
            var meta = NodeMeta(args: "", cwd: "")
            var grandparentPath = ""
            // argv/cwd for node and for everything the Codex engine starts (duplicate detection);
            // the grandparent for anything behind a launcher (npm exec, uv, node_repl).
            if Self.isNode(path) || ProcessClassifier.codexHost(of: parentPath) != nil {
                meta = cachedNodeMeta(pid: pid, key: key)
            }
            if Self.isNode(path) || ProcessClassifier.isRelay(parentPath) {
                let gppid = ppid > 1 ? Self.parent(of: ppid, memo: &ppidMemo) : 0
                grandparentPath = gppid > 1 ? Self.path(of: gppid, memo: &pathMemo) : ""
            }

            samples.append(ProcSample(
                pid: pid, ppid: ppid, path: path, parentPath: parentPath, grandparentPath: grandparentPath,
                args: meta.args, cwd: meta.cwd,
                rssMB: rssMB, footprintMB: footprintMB, ageSec: ageSec, idleSec: idleSec
            ))
        }

        idle.prune(keeping: seen)
        nodeMetaCache = nodeMetaCache.filter { seen.contains($0.key) }
        return samples
    }

    private func cachedNodeMeta(pid: pid_t, key: Key) -> NodeMeta {
        if let m = nodeMetaCache[key] { return m }
        let m = NodeMeta(args: readArgs(pid), cwd: Self.readCwd(pid))
        nodeMetaCache[key] = m
        return m
    }

    private static func readCwd(_ pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    private static func parent(of pid: pid_t, memo: inout [pid_t: pid_t]) -> pid_t {
        if let p = memo[pid] { return p }
        var bsd = proc_bsdinfo()
        let ok = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
        let p = ok ? pid_t(bsd.pbi_ppid) : 0
        memo[pid] = p
        return p
    }

    private func readArgs(_ pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        return ProcArgs.parse(buf, count: size)
    }

    private static func path(of pid: pid_t, memo: inout [pid_t: String]) -> String {
        if let p = memo[pid] { return p }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        let p = n > 0 ? String(cString: buf) : ""
        memo[pid] = p
        return p
    }
}
