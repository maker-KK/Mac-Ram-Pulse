import Darwin
import Testing
@testable import MacRamPulseKit

@Suite("Autopilot patrol rules")
struct PatrolPolicyTests {
    let all = SystemMemoryMonitor.PatrolSettings(cleanIDE: true, trimRenderers: true, cleanCodexDupes: true)
    let defaults = SystemMemoryMonitor.PatrolSettings(cleanIDE: true, trimRenderers: false, cleanCodexDupes: false)
    let idle = SystemMemoryMonitor.daemonIdleSec + 1

    func victims(_ s: [ProcSample], _ cfg: SystemMemoryMonitor.PatrolSettings) -> Set<pid_t> {
        Set(SystemMemoryMonitor.patrolVictims(s, cfg).map(\.sample.pid))
    }

    // Rule 1 — Android Studio JBR java
    @Test("idle JBR daemon is reclaimed when Android Studio is closed")
    func jbrIdleReclaimed() {
        #expect(victims([sample(pid: 1, path: Paths.jbrJava, idleSec: idle)], defaults) == [1])
    }

    @Test("a busy JBR daemon (e.g. CI Gradle build) is never touched")
    func jbrBusyKept() {
        #expect(victims([sample(pid: 1, path: Paths.jbrJava, idleSec: 30)], defaults).isEmpty)
    }

    @Test("JBR daemons are kept while Android Studio is open")
    func jbrKeptWhileStudioOpen() {
        let s = [sample(pid: 1, path: Paths.jbrJava, idleSec: idle), sample(pid: 2, path: Paths.studio)]
        #expect(victims(s, defaults).isEmpty)
    }

    @Test("young JBR daemons (< 5 min) are kept")
    func jbrYoungKept() {
        #expect(victims([sample(pid: 1, path: Paths.jbrJava, ageSec: 200, idleSec: idle)], defaults).isEmpty)
    }

    // Rule 2 — orphaned Dart
    @Test("orphaned, large, idle dart runtime is reclaimed")
    func dartOrphanReclaimed() {
        #expect(victims([sample(pid: 1, ppid: 1, path: Paths.dart, footprintMB: 500, idleSec: idle)], defaults) == [1])
    }

    @Test("dart runtime with a live parent or small footprint is kept", arguments: [(pid_t(77), 500.0), (pid_t(1), 200.0)])
    func dartKept(ppid: pid_t, footprintMB: Double) {
        let s = [sample(pid: 1, ppid: ppid, path: Paths.dart, footprintMB: footprintMB, idleSec: idle)]
        #expect(victims(s, defaults).isEmpty)
    }

    // Rule 3 — SourceKit
    @Test("idle SourceKitService is reclaimed only while Xcode is closed")
    func sourceKit() {
        let sk = sample(pid: 1, path: Paths.sourceKit, idleSec: idle)
        #expect(victims([sk], defaults) == [1])
        #expect(victims([sk, sample(pid: 2, path: Paths.xcode)], defaults).isEmpty)
    }

    // Rule 4 — leaking renderer (opt-in)
    @Test("renderer over 2GB is trimmed only when opted in")
    func renderer() {
        let r = sample(pid: 1, path: Paths.asideRenderer, footprintMB: 2500)
        #expect(victims([r], defaults).isEmpty)
        #expect(victims([r], all) == [1])
        #expect(victims([sample(pid: 1, path: Paths.asideRenderer, footprintMB: 1500)], all).isEmpty)
    }

    // Rule 5 — Codex duplicates (opt-in)
    @Test("Codex duplicate cleanup runs only when opted in")
    func codexDupesOptIn() {
        let s = [
            sample(pid: 1, ppid: 500, path: Paths.cuaNode, parent: Paths.codexAppServer, args: "node a", cwd: "/x", ageSec: 10, idleSec: 9999),
            sample(pid: 2, ppid: 500, path: Paths.cuaNode, parent: Paths.codexAppServer, args: "node a", cwd: "/x", ageSec: 9000, idleSec: 9999),
        ]
        #expect(victims(s, defaults).isEmpty)
        #expect(victims(s, all) == [2])
    }

    @Test("with IDE cleanup off nothing is reclaimed")
    func ideCleanupOff() {
        let off = SystemMemoryMonitor.PatrolSettings(cleanIDE: false, trimRenderers: false, cleanCodexDupes: false)
        let s = [sample(pid: 1, path: Paths.jbrJava, idleSec: idle),
                 sample(pid: 2, ppid: 1, path: Paths.dart, footprintMB: 900, idleSec: idle),
                 sample(pid: 3, path: Paths.sourceKit, idleSec: idle)]
        #expect(victims(s, off).isEmpty)
    }

    @Test("protected processes are never victims, however idle", arguments: [
        Paths.claudeCode, Paths.claudeDesktop, Paths.colimaVM, Paths.standaloneCodex, Paths.antigravity,
    ])
    func protectedNeverVictims(path: String) {
        #expect(victims([sample(pid: 1, ppid: 1, path: path, footprintMB: 9000, ageSec: 99_999, idleSec: 99_999)], all).isEmpty)
    }
}

@Suite("Group aggregation & status title")
struct GroupBuilderTests {
    @Test("aggregates per group, estimates swap, and tracks idle processes")
    func aggregates() {
        let s = [
            sample(pid: 1, path: Paths.chatGPT, rssMB: 200, footprintMB: 500, idleSec: 0),
            sample(pid: 2, path: Paths.codexRenderer, rssMB: 300, footprintMB: 250, idleSec: 120),
            sample(pid: 3, path: Paths.jbrJava, rssMB: 100, footprintMB: 400, idleSec: 120),
        ]
        let result = SystemMemoryMonitor.buildGroups(s)
        let chat = try! #require(result.groups.first { $0.name == "ChatGPT & Codex 앱" })
        #expect(chat.processCount == 2)
        #expect(chat.rssMB == 500)
        #expect(chat.totalMB == 750)
        #expect(chat.swapMB == 300)            // max(0, 500-200) + max(0, 250-300)
        #expect(chat.idlePids == [2])
        #expect(chat.idleMB == 250)
        #expect(result.reclaimableMB == 400)   // only the JBR daemon
    }

    @Test("groups under 35MB are hidden")
    func smallGroupsHidden() {
        let result = SystemMemoryMonitor.buildGroups([sample(pid: 1, path: "/Applications/Tiny.app/Contents/MacOS/Tiny", rssMB: 10, footprintMB: 20)])
        #expect(result.groups.isEmpty)
    }

    @Test("status title colors", arguments: [
        (40, 1.0, 1, "🟢"), (80, 1.0, 1, "🟡"), (40, 6.0, 1, "🟡"), (40, 1.0, 2, "🟡"),
        (90, 1.0, 1, "🔴"), (40, 9.5, 1, "🔴"), (40, 1.0, 4, "🔴"),
    ])
    func statusTitle(usedPct: Int, swapGB: Double, pressure: Int, dot: String) {
        let title = SystemMemoryMonitor.statusTitle(usedPct: usedPct, swapGB: swapGB, pressure: pressure)
        #expect(title.hasPrefix(dot))
        #expect(title.contains("\(usedPct)%"))
    }
}
