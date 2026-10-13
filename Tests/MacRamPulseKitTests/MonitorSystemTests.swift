import Foundation
import Testing
@testable import MacRamPulseKit

/// Read-only checks against the live machine, plus the monitor's scan/patrol plumbing.
/// Signals go to a spy, so nothing on the machine is ever killed.
@Suite("Monitor — live system reads & refresh plumbing", .serialized)
@MainActor
struct MonitorSystemTests {
    @Test("VM statistics are sane")
    func readVM() {
        var s = MemoryStats()
        SystemMemoryMonitor.readVM(into: &s)
        let physicalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        #expect(abs(s.totalGB - physicalGB) < 0.01)
        #expect((0...100).contains(s.usedPercent))
        #expect(s.usedGB > 0 && s.usedGB <= s.totalGB + 0.5)
        #expect(s.swapUsedMB <= s.swapTotalMB)
        #expect([1, 2, 4].contains(s.vmPressureLevel))
    }

    @Test("disk statistics are sane")
    func readDisks() {
        var s = MemoryStats()
        SystemMemoryMonitor.readDisks(into: &s)
        #expect(s.internalTotalGB > 0)
        #expect(s.internalFreeGB <= s.internalTotalGB)
        #expect((0...100).contains(s.internalUsedPct))
    }

    @Test("offload targets report symlink state truthfully")
    func offloadTargets() {
        let targets = SystemMemoryMonitor.readOffloadTargets()
        #expect(targets.count == 5)
        #expect(Set(targets.map(\.id)).count == 5)
        for t in targets {
            let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: t.sourcePath)) != nil
            #expect(t.isOffloaded == isLink, "\(t.sourcePath)")
            if t.isOffloaded { #expect(t.exists) }
        }
    }

    @Test("machine label names the RAM size")
    func machineLabel() {
        #expect(SystemMemoryMonitor.machineLabel.hasSuffix("GB"))
    }

    @Test("full refresh publishes stats and a menu bar title")
    func refreshFullPublishes() async throws {
        let spy = Spy()
        spy.scanResult = nil
        let m = spy.makeMonitor()
        var titles: [String] = []
        m.onUpdateStatusTitle = { titles.append($0) }
        m.refreshFull()
        for _ in 0..<100 where m.stats.groups.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!m.stats.groups.isEmpty)
        #expect(m.stats.scanDurationMs > 0)
        #expect(m.stats.offloadTargets.count == 5)
        #expect(titles.last?.contains("Swp") == true)
    }

    @Test("quick refresh publishes a title on the main thread")
    func quickRefresh() async throws {
        let spy = Spy()
        let m = spy.makeMonitor()
        var onMain = false
        m.onUpdateStatusTitle = { _ in onMain = Thread.isMainThread }
        m.refreshQuickStatusBarOnly()
        for _ in 0..<40 where !onMain { try await Task.sleep(for: .milliseconds(25)) }
        #expect(onMain)
    }

    /// A fresh scanner has seen every process exactly once, so nothing is idle yet:
    /// a manual patrol must report a clean state and send no signals.
    @Test("manual patrol on a fresh scanner reclaims nothing")
    func manualPatrolFreshScanner() async throws {
        let spy = Spy()
        spy.scanResult = nil
        let m = spy.makeMonitor()
        m.runAutoPatrol(manualTrigger: true)
        for _ in 0..<100 where m.lastActionMessage.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(m.lastActionMessage == "✅ 모든 백그라운드 프로세스가 정상 상태입니다.")
        #expect(spy.signals.isEmpty)
        #expect(m.autoLogs.first?.contains("순찰 완료") == true)
    }

    @Test("closing the popover cancels a pending kill confirmation")
    func popoverToggle() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.setPopoverOpen(true)
        #expect(m.isPopoverVisible)
        m.confirmingGroupId = "Google Chrome"
        m.setPopoverOpen(false)
        #expect(!m.isPopoverVisible)
        #expect(m.confirmingGroupId == nil)
    }

    @Test("clearing logs leaves a single reset entry")
    func clearLogs() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.addLog("a"); m.addLog("b")
        m.clearLogs()
        #expect(m.autoLogs.count == 1)
        #expect(m.autoLogs[0].contains("초기화"))
    }

    @Test("default GUI quit helper ignores an empty pid set")
    func quitHelperEmpty() {
        #expect(MonitorEnvironment.quitRunningApps([]) == 0)
    }

    @Test("toast warning detection", arguments: [
        ("⚠️ 이전 확인 필요", true), ("⏳ 작업 중", true), ("ℹ️ 취소", true), ("✅ 완료", false), ("🧹 자동 회수", false),
    ])
    func toastWarning(message: String, isWarning: Bool) {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.lastActionMessage = message
        #expect(m.isToastWarning == isWarning)
    }
}
