import Foundation
import Testing
@testable import MacRamPulseKit

/// Thread-safe counter (scans run on the monitor's background queue).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Records signals instead of sending them; never touches real processes or real preferences.
final class Spy {
    var signals: [(pid_t, Int32)] = []
    var quitRequests: [Set<pid_t>] = []
    var guiAppCount = 0
    var commands: [(String, [String])] = []
    var commandResult = CommandResult(status: 0, output: "완료\n")
    /// nil = live libproc scan
    var scanResult: [ProcSample]? = []
    var confirmTimeout: TimeInterval = 3.5
    /// Timers are effectively off unless a test shortens them.
    var quickRefreshInterval: TimeInterval = 999
    var popoverRefreshInterval: TimeInterval = 999
    var patrolInterval: TimeInterval = 999
    var toastDuration: TimeInterval = 6
    var startsAutomatically = false
    var volumeMounted = true
    var restartResult = true
    var restartCalls: [pid_t] = []
    let scans = Counter()
    /// pid -> current executable path; pids not listed report the path recorded at scan time.
    var currentPaths: [pid_t: String] = [:]
    let suiteName = "MacRamPulseTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suiteName)!

    func makeMonitor() -> SystemMemoryMonitor {
        var env = MonitorEnvironment()
        env.defaults = defaults
        env.startsAutomatically = startsAutomatically
        env.quickRefreshInterval = quickRefreshInterval
        env.popoverRefreshInterval = popoverRefreshInterval
        env.patrolInterval = patrolInterval
        env.toastDuration = toastDuration
        let mounted = volumeMounted
        env.isVolumeMounted = { _ in mounted }
        env.restartApp = { pid in self.restartCalls.append(pid); return self.restartResult }
        env.sendSignal = { pid, sig in self.signals.append((pid, sig)); return 0 }
        env.quitGUIApps = { pids in self.quitRequests.append(pids); return self.guiAppCount }
        env.runCommand = { path, args in self.commands.append((path, args)); return self.commandResult }
        if let scan = scanResult {
            let scans = self.scans
            env.scanOverride = { scans.increment(); return scan }
        }
        env.confirmTimeout = confirmTimeout
        env.currentPath = { pid in self.currentPaths[pid] ?? "" }
        return SystemMemoryMonitor(env: env)
    }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }
}

@Suite("Monitor user actions", .serialized)
@MainActor
struct MonitorActionTests {
    @Test("bulk reclaim signals only idle pids of reclaimable groups")
    func bulkReclaimOnlyIdle() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.stats.groups = [
            group("Android Studio (Java/Gradle 데몬)", pids: [10, 11, 12], idlePids: [10, 11], idleMB: 2048, isReclaimable: true),
            group("Claude", pids: [20], idlePids: [20], isProtected: true),
            group("Google Chrome", pids: [30], idlePids: [30]),
        ]
        m.reclaimIdleDaemonsNow()
        #expect(Set(spy.signals.map(\.0)) == [10, 11])
        #expect(spy.signals.allSatisfy { $0.1 == SIGTERM })
        #expect(m.lastActionMessage.contains("2개"))
        #expect(m.lastActionMessage.contains("작업 중 1개 유지"))
    }

    @Test("bulk reclaim with only busy daemons sends nothing and says so")
    func bulkReclaimAllBusy() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.stats.groups = [group("Flutter / Dart 런타임 데몬", pids: [10], isReclaimable: true)]
        m.reclaimIdleDaemonsNow()
        #expect(spy.signals.isEmpty)
        #expect(m.lastActionMessage.hasPrefix("⏳"))
        #expect(m.isToastWarning)
    }

    @Test("protected groups cannot be terminated")
    func protectedNotTerminated() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.terminateGroup(group("Claude", pids: [1, 2], isProtected: true))
        #expect(spy.signals.isEmpty)
        #expect(spy.quitRequests.isEmpty)
    }

    @Test("GUI apps get a normal Quit, not SIGTERM")
    func guiAppsQuitGracefully() {
        let spy = Spy()
        spy.guiAppCount = 1
        let m = spy.makeMonitor()
        m.confirmingGroupId = "Google Chrome"
        m.terminateGroup(group("Google Chrome", pids: [1, 2, 3]))
        #expect(spy.quitRequests == [[1, 2, 3]])
        #expect(spy.signals.isEmpty)
        #expect(m.confirmingGroupId == nil)
        #expect(m.lastActionMessage.contains("종료 요청"))
    }

    @Test("daemon-only groups get SIGTERM for every pid")
    func daemonsGetSigterm() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.terminateGroup(group("Codex MCP·REPL 하위 서버", pids: [7, 8]))
        #expect(spy.signals.map(\.0) == [7, 8])
    }

    @Test("settings persist to the injected defaults; Codex rule is off by default")
    func settingsPersist() {
        let spy = Spy()
        spy.defaults.set(true, forKey: "MRP_CleanMCP")   // legacy v5.0 key must not enable Rule 5
        let m = spy.makeMonitor()
        #expect(m.cleanCodexDuplicateMCPs == false)
        #expect(m.autoGuardEnabled == true)
        m.cleanCodexDuplicateMCPs = true
        m.autoGuardEnabled = false
        #expect(spy.defaults.bool(forKey: "MRP_CleanCodexDupes") == true)
        #expect(spy.defaults.object(forKey: "MRP_AutoGuard") as? Bool == false)
        #expect(spy.makeMonitor().cleanCodexDuplicateMCPs == true)
    }

    @Test("logs are applied immediately on the main thread and capped")
    func logsCapped() {
        let spy = Spy()
        let m = spy.makeMonitor()
        for i in 0..<60 { m.addLog("entry \(i)") }
        #expect(m.autoLogs.count == SystemMemoryMonitor.maxLogs)
        #expect(m.autoLogs.first?.hasSuffix("entry 59") == true)
        #expect(spy.defaults.stringArray(forKey: "MacRamPulse_AutoLogs")?.count == SystemMemoryMonitor.maxLogs)
    }

    @Test("search and sort over groups")
    func searchAndSort() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.stats.groups = [group("Notion", pids: [1], totalMB: 300), group("Google Chrome", pids: [2], totalMB: 900)]
        m.sortMode = .total
        #expect(m.filteredAndSortedGroups.map(\.name) == ["Google Chrome", "Notion"])
        m.searchText = "  noti "
        #expect(m.filteredAndSortedGroups.map(\.name) == ["Notion"])
    }
}
