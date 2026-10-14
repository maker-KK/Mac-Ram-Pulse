import Darwin
import Foundation
import Testing
@testable import MacRamPulseKit

/// Round 2: things that happen in everyday use — timers, long lists, apps that vanish between
/// refreshes, restarts, an unplugged external SSD, failing commands, number formatting.
/// Nothing real is killed or written: everything goes through the Spy.
@Suite("Daily-use scenarios", .serialized)
@MainActor
struct DailyUseScenarioTests {
    func wait(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    func waitUntilIdle(_ m: SystemMemoryMonitor) async throws {
        for _ in 0..<100 where m.isBusy { try await wait(0.02) }
        try await wait(0.05)
    }

    func rows(_ n: Int, mb: (Int) -> Double = { Double(1000 - $0) }) -> [AppGroupMemory] {
        (0..<n).map { i in
            AppGroupMemory(name: String(format: "App %02d", i), icon: "📦", rssMB: mb(i), swapMB: mb(i), totalMB: 2 * mb(i),
                           processCount: 1, pids: [pid_t(i + 1)], idlePids: [], idleMB: 0,
                           isProtected: false, isReclaimableDaemon: false)
        }
    }

    // MARK: Menu bar title (1–9)

    @Test("memory % boundaries for the menu bar dot", arguments: [(75, "🟢"), (76, "🟡"), (88, "🟡"), (89, "🔴")])
    func usedPercentBoundaries(pct: Int, dot: String) {
        #expect(SystemMemoryMonitor.statusTitle(usedPct: pct, swapGB: 0.5, pressure: 1).hasPrefix(dot))
    }

    @Test("swap boundaries for the menu bar dot", arguments: [(5.0, "🟢"), (5.1, "🟡"), (9.0, "🟡"), (9.1, "🔴")])
    func swapBoundaries(swap: Double, dot: String) {
        #expect(SystemMemoryMonitor.statusTitle(usedPct: 40, swapGB: swap, pressure: 1).hasPrefix(dot))
    }

    @Test("swap in the title is shown with one decimal")
    func titleSwapFormat() {
        #expect(SystemMemoryMonitor.statusTitle(usedPct: 71, swapGB: 12.34, pressure: 1) == "🔴 71% · Swp 12.3G")
    }

    // MARK: Popover & timers (10–16)

    @Test("an open popover keeps refreshing the app list")
    func popoverRefreshes() async throws {
        let spy = Spy()
        spy.popoverRefreshInterval = 0.05
        let m = spy.makeMonitor()
        m.setPopoverOpen(true)
        try await wait(0.4)
        m.setPopoverOpen(false)
        #expect(spy.scans.value >= 4)
    }

    @Test("closing the popover stops list refreshes")
    func popoverCloseStopsRefresh() async throws {
        let spy = Spy()
        spy.popoverRefreshInterval = 0.05
        let m = spy.makeMonitor()
        m.setPopoverOpen(true)
        try await wait(0.2)
        m.setPopoverOpen(false)
        try await wait(0.1)
        let after = spy.scans.value
        try await wait(0.3)
        #expect(spy.scans.value == after)
    }

    @Test("opening an already open popover does not double the refresh rate")
    func reopenDoesNotDouble() async throws {
        let spy = Spy()
        spy.popoverRefreshInterval = 0.1
        let m = spy.makeMonitor()
        m.setPopoverOpen(true)
        m.setPopoverOpen(true)
        m.setPopoverOpen(true)
        try await wait(0.55)
        m.setPopoverOpen(false)
        #expect(spy.scans.value <= 3 + 6 + 1)   // 3 immediate refreshes + one timer's ticks
    }

    @Test("the menu bar title keeps updating while the popover is closed")
    func quickRefreshWhileClosed() async throws {
        let spy = Spy()
        spy.quickRefreshInterval = 0.05
        spy.startsAutomatically = true
        let m = spy.makeMonitor()
        let titles = Counter()
        m.onUpdateStatusTitle = { _ in titles.increment() }
        try await wait(0.4)
        #expect(titles.value >= 4)
        _ = m
    }

    @Test("timers pause while a command is running")
    func timersPauseWhileBusy() async throws {
        let spy = Spy()
        spy.popoverRefreshInterval = 0.05
        let m = spy.makeMonitor()
        m.setPopoverOpen(true)
        try await wait(0.1)
        m.isBusy = true
        try await wait(0.05)
        let before = spy.scans.value
        try await wait(0.3)
        #expect(spy.scans.value == before)
        m.isBusy = false
        m.setPopoverOpen(false)
    }

    @Test("autopilot off: the patrol timer never scans", arguments: [false, true])
    func patrolRespectsToggle(enabled: Bool) async throws {
        let spy = Spy()
        spy.patrolInterval = 0.05
        spy.defaults.set(enabled, forKey: "MRP_AutoGuard")
        spy.startsAutomatically = true
        let m = spy.makeMonitor()
        try await wait(0.15)
        let initial = spy.scans.value
        try await wait(0.4)
        let patrols = spy.scans.value - initial
        if enabled { #expect(patrols >= 3) } else { #expect(patrols == 0) }
        _ = m
    }

    // MARK: Long lists & search (17–22)

    @Test("a whitespace-only search shows every app")
    func whitespaceSearch() {
        let m = Spy().makeMonitor()
        m.stats.groups = rows(5)
        m.searchText = "   "
        #expect(m.filteredAndSortedGroups.count == 5)
        #expect(!m.hasNoSearchResults)
    }

    @Test("search matches names with parentheses and dots")
    func searchSpecialCharacters() {
        let m = Spy().makeMonitor()
        m.stats.groups = [group("Android Studio (Java/Gradle 데몬)", pids: [1]), group("Codex MCP·REPL 하위 서버", pids: [2])]
        m.searchText = "(java"
        #expect(m.filteredAndSortedGroups.map(\.name) == ["Android Studio (Java/Gradle 데몬)"])
        m.searchText = "mcp·repl"
        #expect(m.filteredAndSortedGroups.count == 1)
    }

    @Test("the search filter survives a list refresh and a sort change")
    func searchSurvivesRefreshAndSort() {
        let m = Spy().makeMonitor()
        m.stats.groups = rows(8)
        m.searchText = "App 0"
        let before = m.filteredAndSortedGroups.count
        m.stats.groups = rows(8).reversed()
        m.sortMode = .ram
        #expect(m.filteredAndSortedGroups.count == before)
        #expect(m.filteredAndSortedGroups.allSatisfy { $0.name.hasPrefix("App 0") })
    }

    /// With dozens of apps open, rows past the visible limit used to vanish without a hint.
    @Test("apps beyond the visible rows are counted so the user knows to search")
    func hiddenRowsAreCounted() {
        let m = Spy().makeMonitor()
        m.stats.groups = rows(20)
        #expect(m.visibleGroups.count == SystemMemoryMonitor.maxVisibleRows)
        #expect(m.hiddenGroupCount == 5)
    }

    @Test("a hidden app is reachable by search")
    func hiddenRowReachableBySearch() {
        let m = Spy().makeMonitor()
        m.stats.groups = rows(20)
        m.searchText = "App 19"
        #expect(m.visibleGroups.map(\.name) == ["App 19"])
        #expect(m.hiddenGroupCount == 0)
    }

    @Test("no hidden-row hint when everything fits")
    func noHiddenHintWhenFits() {
        let m = Spy().makeMonitor()
        m.stats.groups = rows(10)
        #expect(m.hiddenGroupCount == 0)
    }

    // MARK: Apps that change between refreshes (23–27)

    /// The user arms "정리" on an app that then quits on its own; if another app with that name
    /// appears later, it must not show up already armed.
    @Test("an armed app that disappears on refresh is disarmed")
    func armedAppDisappears() {
        let m = Spy().makeMonitor()
        m.stats.groups = [group("Slack", pids: [1]), group("Notion", pids: [2])]
        m.requestTerminate(m.stats.groups[0])
        m.stats.groups = [group("Notion", pids: [2])]
        #expect(m.confirmingGroupId == nil)
    }

    @Test("an armed app that is still listed after refresh stays armed")
    func armedAppStillListed() {
        let m = Spy().makeMonitor()
        m.stats.groups = [group("Slack", pids: [1])]
        m.requestTerminate(m.stats.groups[0])
        m.stats.groups = [group("Slack", pids: [1, 7])]
        #expect(m.confirmingGroupId == "Slack")
    }

    @Test("종료확인 acts on the refreshed row's current processes")
    func confirmUsesRefreshedPids() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.stats.groups = [group("Slack", pids: [1])]
        m.requestTerminate(m.stats.groups[0])
        m.stats.groups = [group("Slack", pids: [1, 7])]
        m.confirmTerminate(m.stats.groups[0])
        #expect(spy.signals.map(\.0) == [1, 7])
    }

    @Test("terminating reports the app name and roughly how much it held")
    func terminateMessage() {
        let m = Spy().makeMonitor()
        let slack = group("Slack", pids: [1], totalMB: 1536)
        m.requestTerminate(slack)
        m.confirmTerminate(slack)
        #expect(m.lastActionMessage.contains("Slack"))
        #expect(m.lastActionMessage.contains("1.5GB"))
    }

    @Test("bulk reclaim never touches protected or regular apps, even if idle")
    func bulkReclaimScope() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.stats.groups = [
            group("Claude", pids: [1], idlePids: [1], isProtected: true),
            group("Google Chrome", pids: [2], idlePids: [2]),
            group("Flutter / Dart 런타임 데몬", pids: [3], idlePids: [3], idleMB: 500, isReclaimable: true),
        ]
        m.reclaimIdleDaemonsNow()
        #expect(spy.signals.map(\.0) == [3])
    }

    // MARK: Reclaim accounting (28–31)

    /// If a pid was skipped because it no longer runs the same program, its memory must not be
    /// counted as freed.
    @Test("freed memory counts only processes that were actually signalled")
    func freedCountsOnlySignalled() {
        let spy = Spy()
        spy.currentPaths = [1: Paths.jbrJava, 2: "/usr/bin/vim"]
        let m = spy.makeMonitor()
        var gradle = group("Android Studio (Java/Gradle 데몬)", pids: [1, 2], idlePids: [1, 2], idleMB: 3072, isReclaimable: true)
        gradle.pidPaths = [1: Paths.jbrJava, 2: Paths.jbrJava]
        gradle.pidMB = [1: 1024, 2: 2048]
        m.stats.groups = [gradle]
        m.reclaimIdleDaemonsNow()
        #expect(spy.signals.map(\.0) == [1])
        #expect(m.lastActionMessage.contains("1개"))
        #expect(m.lastActionMessage.contains("1.0GB"))
    }

    @Test("if every idle daemon already exited, nothing is claimed as reclaimed")
    func allAlreadyGone() {
        let spy = Spy()
        spy.currentPaths = [1: ""]
        let m = spy.makeMonitor()
        var gradle = group("Android Studio (Java/Gradle 데몬)", pids: [1], idlePids: [1], idleMB: 900, isReclaimable: true)
        gradle.pidPaths = [1: Paths.jbrJava]
        m.stats.groups = [gradle]
        m.reclaimIdleDaemonsNow()
        #expect(spy.signals.isEmpty)
        #expect(m.lastActionMessage.hasPrefix("ℹ️"))
        #expect(!m.autoLogs.contains { $0.contains("회수 완료") })
    }

    @Test("bulk reclaim across two daemon groups")
    func bulkAcrossGroups() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.stats.groups = [
            group("Android Studio (Java/Gradle 데몬)", pids: [1, 2], idlePids: [1, 2], idleMB: 2048, isReclaimable: true),
            group("Flutter / Dart 런타임 데몬", pids: [3, 4], idlePids: [4], idleMB: 512, isReclaimable: true),
        ]
        m.reclaimIdleDaemonsNow()
        #expect(Set(spy.signals.map(\.0)) == [1, 2, 4])
        #expect(m.lastActionMessage.contains("3개"))
        #expect(m.lastActionMessage.contains("작업 중 1개 유지"))
    }

    @Test("bulk reclaim with no daemons says so")
    func bulkNothing() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.stats.groups = [group("Google Chrome", pids: [1], idlePids: [1])]
        m.reclaimIdleDaemonsNow()
        #expect(spy.signals.isEmpty)
        #expect(m.lastActionMessage.hasPrefix("✅"))
    }

    // MARK: Restart persistence (32–40)

    @Test("each autopilot switch survives an app restart", arguments: [
        "autoGuardEnabled", "cleanOrphanedIDEDaemons", "trimBloatedRenderers", "cleanCodexDuplicateMCPs",
    ])
    func togglePersists(name: String) {
        let spy = Spy()
        let m = spy.makeMonitor()
        let kp: ReferenceWritableKeyPath<SystemMemoryMonitor, Bool> = [
            "autoGuardEnabled": \SystemMemoryMonitor.autoGuardEnabled,
            "cleanOrphanedIDEDaemons": \SystemMemoryMonitor.cleanOrphanedIDEDaemons,
            "trimBloatedRenderers": \SystemMemoryMonitor.trimBloatedRenderers,
            "cleanCodexDuplicateMCPs": \SystemMemoryMonitor.cleanCodexDuplicateMCPs,
        ][name]!
        let flipped = !m[keyPath: kp]
        m[keyPath: kp] = flipped
        #expect(spy.makeMonitor()[keyPath: kp] == flipped)
    }

    @Test("first launch defaults: autopilot and IDE cleanup on, opt-in rules off")
    func firstLaunchDefaults() {
        let m = Spy().makeMonitor()
        #expect(m.autoGuardEnabled && m.cleanOrphanedIDEDaemons)
        #expect(!m.trimBloatedRenderers && !m.cleanCodexDuplicateMCPs)
        #expect(m.autoLogs.count == 2)
    }

    @Test("activity log and totals survive an app restart")
    func logsPersist() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.addLog("persist me")
        spy.defaults.set(1234.0, forKey: "MacRamPulse_TotalSavedMB")
        let again = spy.makeMonitor()
        #expect(again.autoLogs.first?.hasSuffix("persist me") == true)
        #expect(again.totalSavedMB == 1234)
    }

    @Test("a log written from a background thread shows up on the main thread")
    func backgroundLog() async throws {
        let m = Spy().makeMonitor()
        DispatchQueue.global().async { m.addLog("from background") }
        for _ in 0..<50 where m.autoLogs.first?.hasSuffix("from background") != true { try await wait(0.02) }
        #expect(m.autoLogs.first?.hasSuffix("from background") == true)
    }

    @Test("log entries carry an HH:mm:ss timestamp")
    func logTimestamp() {
        let m = Spy().makeMonitor()
        m.addLog("x")
        #expect(m.autoLogs[0].range(of: #"^\[\d{2}:\d{2}:\d{2}\] x$"#, options: .regularExpression) != nil)
    }

    @Test("clearing the log keeps the reclaimed-memory totals")
    func clearKeepsTotals() {
        let spy = Spy()
        spy.defaults.set(500.0, forKey: "MacRamPulse_TotalSavedMB")
        spy.defaults.set(3, forKey: "MacRamPulse_TotalCleanCount")
        let m = spy.makeMonitor()
        m.clearLogs()
        #expect(m.totalSavedMB == 500 && m.totalCleanCount == 3)
    }

    // MARK: Toast (41–42)

    @Test("the status toast disappears on its own")
    func toastAutoDismiss() async throws {
        let spy = Spy()
        spy.toastDuration = 0.1
        let m = spy.makeMonitor()
        m.lastActionMessage = "✅ 완료"
        try await wait(0.25)
        #expect(m.lastActionMessage.isEmpty)
    }

    @Test("a newer toast is not cleared by the older one's timer")
    func newerToastSurvives() async throws {
        let spy = Spy()
        spy.toastDuration = 0.2
        let m = spy.makeMonitor()
        m.lastActionMessage = "first"
        try await wait(0.12)
        m.lastActionMessage = "second"
        try await wait(0.12)                 // the first timer would have fired by now
        #expect(m.lastActionMessage == "second")
    }

    // MARK: External SSD & commands (43–50)

    @Test("an unplugged external SSD is reported as not mounted, not as 0 GB free")
    func unpluggedSSDStats() {
        var s = MemoryStats()
        SystemMemoryMonitor.readDisks(into: &s, externalPath: "/Volumes/NoSuchDisk-\(UUID().uuidString)")
        #expect(!s.externalMounted)
        #expect(s.externalTotalGB == 0 && s.externalFreeGB == 0)
        var real = MemoryStats()
        SystemMemoryMonitor.readDisks(into: &real, externalPath: "/")
        #expect(real.externalMounted && real.externalTotalGB > 0)
    }

    @Test("외장 이전 is refused when the external SSD is not connected")
    func offloadNeedsSSD() async throws {
        let spy = Spy()
        spy.volumeMounted = false
        let m = spy.makeMonitor()
        m.offloadToExternalSSD(UserScenarioTests.npmTarget)
        try await waitUntilIdle(m)
        #expect(spy.commands.isEmpty)
        #expect(m.lastActionMessage.hasPrefix("⚠️"))
        #expect(m.lastActionMessage.contains("외장 SSD"))
    }

    @Test("the offload script's own failure reason is shown")
    func offloadScriptReason() async throws {
        let spy = Spy()
        spy.commandResult = CommandResult(status: 1, output: "SSD에 같은 이름이 이미 있음: /Volumes/ExternalSSD/MacOffload/npm\n")
        let m = spy.makeMonitor()
        m.offloadToExternalSSD(UserScenarioTests.npmTarget)
        try await waitUntilIdle(m)
        #expect(m.lastActionMessage.contains("같은 이름이 이미 있음"))
    }

    @Test("a command that cannot even start is reported as a failure", arguments: ["purge", "offload", "simulators"])
    func launchFailure(action: String) async throws {
        let spy = Spy()
        spy.commandResult = CommandResult(status: -1, output: "The file “osascript” doesn’t exist.")
        let m = spy.makeMonitor()
        switch action {
        case "purge": m.purgePhysicalRAMCache()
        case "offload": m.offloadToExternalSSD(UserScenarioTests.npmTarget)
        default: m.cleanUnavailableSimulators()
        }
        try await waitUntilIdle(m)
        #expect(m.lastActionMessage.hasPrefix("⚠️"))
        #expect(!m.isBusy)
    }

    @Test("buttons work again after a failed command")
    func usableAfterFailure() async throws {
        let spy = Spy()
        spy.commandResult = CommandResult(status: 72, output: "boom")
        let m = spy.makeMonitor()
        m.cleanUnavailableSimulators()
        try await waitUntilIdle(m)
        spy.commandResult = CommandResult(status: 0, output: "")
        m.cleanUnavailableSimulators()
        try await waitUntilIdle(m)
        #expect(spy.commands.count == 2)
        #expect(m.lastActionMessage.hasPrefix("✅"))
    }

    // MARK: Number formatting (51–55)

    @Test("short sizes switch to GB without showing '1024M'", arguments: [
        (1023.4, "1023M"), (1023.6, "1.0G"), (1536.0, "1.5G"), (0.4, "0M"),
    ])
    func formatShort(mb: Double, text: String) {
        #expect(PulsePopoverView(monitor: Spy().makeMonitor()).formatShort(mb) == text)
    }

    @Test("long sizes switch to GB without showing '1024MB'", arguments: [(1023.6, "1.00GB"), (900.0, "900MB")])
    func formatLong(mb: Double, text: String) {
        #expect(PulsePopoverView(monitor: Spy().makeMonitor()).formatMB(mb) == text)
    }

    // MARK: Scale (56–57)

    @Test("grouping 2,000 processes stays fast")
    func groupingScales() {
        let samples = (0..<2000).map { i in
            sample(pid: pid_t(i + 10), path: "/Applications/App\(i % 60).app/Contents/MacOS/App\(i % 60)",
                   rssMB: 40, footprintMB: 60, idleSec: Double(i % 3) * 100)
        }
        // Best of 5 so a busy machine (e.g. a CI job running alongside) doesn't make it flaky.
        var best = Double.infinity
        var result = SystemMemoryMonitor.buildGroups([])
        for _ in 0..<5 {
            let start = Date()
            result = SystemMemoryMonitor.buildGroups(samples)
            best = min(best, Date().timeIntervalSince(start))
        }
        #expect(best < 0.05)
        #expect(result.groups.count == 60)
    }

    @Test("apps in /Applications/Utilities are named by their bundle")
    func utilitiesApp() {
        let info = ProcessClassifier.classify(sample(pid: 1, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"))
        #expect(info?.name == "Terminal")
    }
}
