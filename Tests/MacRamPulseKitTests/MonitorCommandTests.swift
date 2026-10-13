import Darwin
import Foundation
import Testing
@testable import MacRamPulseKit

@Suite("Monitor — patrol results & external commands", .serialized)
@MainActor
struct MonitorCommandTests {
    func waitUntilIdle(_ m: SystemMemoryMonitor) async throws {
        for _ in 0..<100 where m.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("patrol with victims signals them, records stats and persists totals")
    func patrolWithVictims() async throws {
        let spy = Spy()
        spy.scanResult = [
            sample(pid: 4242, path: Paths.jbrJava, footprintMB: 1500, ageSec: 900, idleSec: SystemMemoryMonitor.daemonIdleSec + 60),
            sample(pid: 4343, path: Paths.claudeCode, footprintMB: 900, ageSec: 99_999, idleSec: 99_999),
        ]
        let m = spy.makeMonitor()
        m.runAutoPatrol(manualTrigger: true)
        for _ in 0..<100 where m.lastActionMessage.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(spy.signals.map(\.0) == [4242])
        #expect(m.totalCleanCount == 1)
        #expect(m.totalSavedMB == 1500)
        #expect(m.lastActionMessage.hasPrefix("🧹 자동 회수"))
        #expect(spy.defaults.integer(forKey: "MacRamPulse_TotalCleanCount") == 1)
    }

    @Test("cache purge: success and cancellation", arguments: [(Int32(0), "✅"), (Int32(1), "ℹ️")])
    func purge(status: Int32, prefix: String) async throws {
        let spy = Spy()
        spy.commandResult = CommandResult(status: status, output: "")
        let m = spy.makeMonitor()
        m.purgePhysicalRAMCache()
        #expect(m.isBusy)
        try await waitUntilIdle(m)
        #expect(!m.isBusy)
        #expect(spy.commands.first?.0 == "/usr/bin/osascript")
        #expect(m.lastActionMessage.hasPrefix(prefix))
    }

    let target = OffloadTarget(id: "npm", title: "NPM", desc: "", sourcePath: "/tmp/x", offloadName: "npm",
                               estimatedSize: "", isOffloaded: false, exists: true)

    @Test("offload succeeds on exit 0 (including 'already linked')")
    func offloadSuccess() async throws {
        let spy = Spy()
        spy.commandResult = CommandResult(status: 0, output: "이미 링크됨: /tmp/x -> /Volumes/ExternalSSD/MacOffload/npm\n")
        let m = spy.makeMonitor()
        m.offloadToExternalSSD(target)
        try await waitUntilIdle(m)
        #expect(spy.commands.first?.1 == ["/Volumes/ExternalSSD/MacOffload/offload.sh", "/tmp/x", "npm"])
        #expect(m.lastActionMessage.hasPrefix("✅"))
    }

    /// The script prints progress lines before failing; success must come from the exit status.
    @Test("offload failure is reported from the exit status, with the last output line")
    func offloadFailure() async throws {
        let spy = Spy()
        spy.commandResult = CommandResult(status: 1, output: "[1/4] 복사 완료 직전\n  항목 수 불일치 — 중단\n")
        let m = spy.makeMonitor()
        m.offloadToExternalSSD(target)
        try await waitUntilIdle(m)
        #expect(m.lastActionMessage.hasPrefix("⚠️"))
        #expect(m.lastActionMessage.contains("항목 수 불일치"))
    }

    @Test("already-offloaded targets run nothing")
    func offloadAlreadyDone() {
        let spy = Spy()
        let m = spy.makeMonitor()
        var done = target
        done.isOffloaded = true
        m.offloadToExternalSSD(done)
        #expect(spy.commands.isEmpty)
        #expect(!m.isBusy)
    }

    @Test("simulator cleanup reports failure instead of claiming success")
    func simulatorFailure() async throws {
        let spy = Spy()
        spy.commandResult = CommandResult(status: 72, output: "xcrun: error: unable to find utility \"simctl\"\n")
        let m = spy.makeMonitor()
        m.cleanUnavailableSimulators()
        try await waitUntilIdle(m)
        #expect(m.lastActionMessage.hasPrefix("⚠️"))
        #expect(!m.autoLogs.contains { $0.contains("정리 완료") })
    }

    @Test("simulator cleanup success")
    func simulatorSuccess() async throws {
        let spy = Spy()
        let m = spy.makeMonitor()
        m.cleanUnavailableSimulators()
        try await waitUntilIdle(m)
        #expect(spy.commands.first?.1 == ["simctl", "delete", "unavailable"])
        #expect(m.lastActionMessage.hasPrefix("✅"))
    }

    @Test("real command runner captures status and output, and survives a missing binary")
    func realRunner() {
        let ok = MonitorEnvironment.runProcess("/bin/echo", ["hello"])
        #expect(ok.status == 0)
        #expect(ok.lastLine == "hello")
        let fail = MonitorEnvironment.runProcess("/bin/sh", ["-c", "echo boom >&2; exit 3"])
        #expect(fail.status == 3)
        #expect(fail.output.contains("boom"))
        let missing = MonitorEnvironment.runProcess("/nonexistent/tool", [])
        #expect(missing.status == -1)
    }
}
