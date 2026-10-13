import Darwin
import Foundation
import Testing
@testable import MacRamPulseKit

/// What a real user does in the popover, step by step. Nothing real is killed: signals, Quit
/// requests, commands and process lookups all go to the Spy.
@Suite("User scenarios", .serialized)
@MainActor
struct UserScenarioTests {
    func wait(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    func waitUntilIdle(_ m: SystemMemoryMonitor) async throws {
        for _ in 0..<100 where m.isBusy { try await wait(0.02) }
        try await wait(0.05)
    }

    // MARK: 정리 → 종료확인 (two-step terminate)

    @Test("first tap on 정리 only arms the row; the second tap terminates")
    func twoStepTerminate() {
        let spy = Spy()
        let m = spy.makeMonitor()
        let chrome = group("Google Chrome", pids: [1, 2])
        m.requestTerminate(chrome)
        #expect(m.confirmingGroupId == "Google Chrome")
        #expect(spy.signals.isEmpty && spy.quitRequests.isEmpty)
        m.confirmTerminate(chrome)
        #expect(spy.signals.map(\.0) == [1, 2])
    }

    @Test("an armed row disarms itself after the timeout")
    func confirmationExpires() async throws {
        let spy = Spy()
        spy.confirmTimeout = 0.15
        let m = spy.makeMonitor()
        m.requestTerminate(group("Slack", pids: [1]))
        try await wait(0.3)
        #expect(m.confirmingGroupId == nil)
    }

    @Test("re-arming the same row restarts the timeout instead of expiring early")
    func rearmRestartsTimeout() async throws {
        let spy = Spy()
        spy.confirmTimeout = 0.3
        let m = spy.makeMonitor()
        let slack = group("Slack", pids: [1])
        m.requestTerminate(slack)
        try await wait(0.2)
        m.requestTerminate(slack)          // user taps again just before it expires
        try await wait(0.2)                // first timer would fire here
        #expect(m.confirmingGroupId == "Slack")
    }

    @Test("arming another row disarms the first; confirming the first then does nothing")
    func armingAnotherRowDisarmsFirst() {
        let spy = Spy()
        let m = spy.makeMonitor()
        let chrome = group("Google Chrome", pids: [1])
        let slack = group("Slack", pids: [2])
        m.requestTerminate(chrome)
        m.requestTerminate(slack)
        m.confirmTerminate(chrome)         // a stale 종료확인 click on the first row
        #expect(spy.signals.isEmpty)
        #expect(m.confirmingGroupId == "Slack")
    }

    @Test("double-clicking 종료확인 terminates only once")
    func doubleClickConfirm() {
        let spy = Spy()
        spy.guiAppCount = 1
        let m = spy.makeMonitor()
        let notion = group("Notion", pids: [5])
        m.requestTerminate(notion)
        m.confirmTerminate(notion)
        m.confirmTerminate(notion)
        #expect(spy.quitRequests.count == 1)
        #expect(m.autoLogs.filter { $0.contains("Notion") }.count == 1)
    }

    @Test("closing the popover disarms; confirming after reopening does nothing")
    func popoverCloseDisarms() {
        let spy = Spy()
        let m = spy.makeMonitor()
        let chrome = group("Google Chrome", pids: [1])
        m.setPopoverOpen(true)
        m.requestTerminate(chrome)
        m.setPopoverOpen(false)
        m.setPopoverOpen(true)
        m.confirmTerminate(chrome)
        #expect(spy.signals.isEmpty)
    }

    @Test("protected rows cannot be armed or terminated")
    func protectedRow() {
        let spy = Spy()
        let m = spy.makeMonitor()
        let claude = group("Claude", pids: [9], isProtected: true)
        m.requestTerminate(claude)
        m.confirmingGroupId = "Claude"     // even if the state were somehow armed
        m.confirmTerminate(claude)
        #expect(spy.signals.isEmpty && spy.quitRequests.isEmpty)
    }

    // MARK: 회수 on a build daemon

    /// The promo promises "빌드 중인 건 안 건드림": a row with a busy daemon must not kill it.
    @Test("회수 on a daemon row reclaims only its idle processes")
    func rowReclaimSparesBusyDaemons() {
        let spy = Spy()
        let m = spy.makeMonitor()
        let gradle = group("Android Studio (Java/Gradle 데몬)", pids: [10, 11], idlePids: [10], idleMB: 900, isReclaimable: true)
        m.requestTerminate(gradle)
        #expect(spy.signals.map(\.0) == [10])
        #expect(m.lastActionMessage.contains("작업 중 1개 유지"))
    }

    @Test("회수 on a fully busy daemon row sends nothing and explains why")
    func rowReclaimAllBusy() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.requestTerminate(group("Flutter / Dart 런타임 데몬", pids: [20], isReclaimable: true))
        #expect(spy.signals.isEmpty)
        #expect(m.lastActionMessage.hasPrefix("⏳"))
    }

    @Test("the '유휴 데몬' badge only shows when every process of the row is idle")
    func idleBadge() {
        #expect(group("G", pids: [1, 2], idlePids: [1, 2], isReclaimable: true).showsIdleBadge)
        #expect(!group("G", pids: [1, 2], idlePids: [1], isReclaimable: true).showsIdleBadge)
        #expect(!group("Chrome", pids: [1], idlePids: [1]).showsIdleBadge)
    }

    // MARK: Stale snapshot (pid reuse)

    /// The list can be up to 3 s old; a pid may have exited and been reused by another program.
    @Test("pids whose executable changed since the scan are not signalled")
    func stalePidNotSignalled() {
        let spy = Spy()
        spy.currentPaths = [1: "/Applications/Slack.app/Contents/MacOS/Slack", 2: "/usr/bin/vim"]
        let m = spy.makeMonitor()
        var slack = group("Slack", pids: [1, 2])
        slack.pidPaths = [1: "/Applications/Slack.app/Contents/MacOS/Slack",
                          2: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"]
        m.requestTerminate(slack)
        m.confirmTerminate(slack)
        #expect(spy.signals.map(\.0) == [1])
    }

    // MARK: Search & sort

    @Test("a search with no match is reported as an empty result, and clearing restores the list")
    func searchNoMatch() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.stats.groups = [group("Notion", pids: [1]), group("Slack", pids: [2])]
        m.searchText = "photoshop"
        #expect(m.filteredAndSortedGroups.isEmpty)
        #expect(m.hasNoSearchResults)
        m.searchText = ""
        #expect(m.filteredAndSortedGroups.count == 2)
        #expect(!m.hasNoSearchResults)
    }

    @Test("search is case-insensitive and matches Korean names")
    func searchCaseAndKorean() {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.stats.groups = [group("Google Chrome", pids: [1]), group("Flutter / Dart 런타임 데몬", pids: [2])]
        m.searchText = "CHROME"
        #expect(m.filteredAndSortedGroups.map(\.name) == ["Google Chrome"])
        m.searchText = "데몬"
        #expect(m.filteredAndSortedGroups.map(\.name) == ["Flutter / Dart 런타임 데몬"])
    }

    /// Groups come out of a Dictionary, so their order differs on every 3 s refresh; equal keys
    /// must not make rows jump around under the user's cursor.
    @Test("rows with equal sort keys keep a stable order across refreshes", arguments: SortMode.allCases)
    func stableSort(mode: SortMode) {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.sortMode = mode
        let rows = ["Zed", "Alpha", "Mail", "Bear", "Kiwi"].enumerated().map { i, name in
            AppGroupMemory(name: name, icon: "📦", rssMB: 100, swapMB: 0, totalMB: 100, processCount: 1,
                           pids: [pid_t(i + 1)], idlePids: [], idleMB: 0, isProtected: false, isReclaimableDaemon: false)
        }
        var orders = Set<[String]>()
        for seed in 0..<12 {
            m.stats.groups = seed % 2 == 0 ? rows.shuffled() : rows.reversed()
            orders.insert(m.filteredAndSortedGroups.map(\.name))
        }
        #expect(orders.count == 1)
        #expect(orders.first == ["Alpha", "Bear", "Kiwi", "Mail", "Zed"])
    }

    // MARK: Buttons that run commands

    @Test("cache purge: cancelling the admin prompt vs. a real failure", arguments: [
        ("execution error: User canceled. (-128)", "ℹ️"),
        ("execution error: purge: Operation not permitted (1)", "⚠️"),
    ])
    func purgeCancelVsFailure(output: String, prefix: String) async throws {
        let spy = Spy()
        spy.commandResult = CommandResult(status: 1, output: output)
        let m = spy.makeMonitor()
        m.purgePhysicalRAMCache()
        try await waitUntilIdle(m)
        #expect(m.lastActionMessage.hasPrefix(prefix))
    }

    @Test("tapping a command button again while one is running starts nothing new")
    func noDoubleRunWhileBusy() async throws {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.purgePhysicalRAMCache()
        m.purgePhysicalRAMCache()
        m.cleanUnavailableSimulators()
        try await waitUntilIdle(m)
        #expect(spy.commands.count == 1)
    }

    static let gradleTarget = OffloadTarget(id: "gradle", title: "Gradle 빌드 & 데몬 캐시 (~/.gradle)", desc: "",
                                            sourcePath: "/Users/me/.gradle", offloadName: "gradle",
                                            estimatedSize: "", isOffloaded: false, exists: true)
    static let npmTarget = OffloadTarget(id: "npm", title: "Node / NPM 글로벌 캐시 (~/.npm)", desc: "",
                                         sourcePath: "/Users/me/.npm", offloadName: "npm",
                                         estimatedSize: "", isOffloaded: false, exists: true)

    /// Moving ~/.gradle while a Gradle daemon has it open can corrupt the cache mid-build.
    @Test("외장 이전 is refused while a Gradle daemon is running")
    func offloadBlockedByRunningGradle() async throws {
        let spy = Spy()
        spy.scanResult = [sample(pid: 1, path: Paths.jbrJava)]
        let m = spy.makeMonitor()
        m.offloadToExternalSSD(Self.gradleTarget)
        try await waitUntilIdle(m)
        #expect(spy.commands.isEmpty)
        #expect(m.lastActionMessage.hasPrefix("⚠️"))
        #expect(m.lastActionMessage.contains("java"))
    }

    /// MCP servers started with `npx` run straight out of ~/.npm/_npx.
    @Test("외장 이전 of ~/.npm is refused while an npx-launched server runs from it")
    func offloadBlockedByNpx() async throws {
        let spy = Spy()
        spy.scanResult = [sample(pid: 1, path: Paths.node, args: "node /Users/me/.npm/_npx/8d09/node_modules/serve/build/main.js")]
        let m = spy.makeMonitor()
        m.offloadToExternalSSD(Self.npmTarget)
        try await waitUntilIdle(m)
        #expect(spy.commands.isEmpty)
        #expect(m.lastActionMessage.hasPrefix("⚠️"))
    }

    @Test("외장 이전 runs when nothing is using the folder")
    func offloadRunsWhenFree() async throws {
        let spy = Spy()
        spy.scanResult = [sample(pid: 1, path: Paths.claudeCode), sample(pid: 2, path: Paths.node, args: "node /opt/app/server.js")]
        let m = spy.makeMonitor()
        m.offloadToExternalSSD(Self.npmTarget)
        try await waitUntilIdle(m)
        #expect(spy.commands.first?.1.last == "npm")
        #expect(m.lastActionMessage.hasPrefix("✅"))
    }
}
