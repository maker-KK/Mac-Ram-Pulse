import Darwin
import Testing
@testable import MacRamPulseKit

@Suite("IdleTracker — CPU idle time across scans")
struct IdleTrackerTests {
    let key = IdleTracker.Key(pid: 42, startAbs: 1000)

    @Test("first sighting counts as active")
    func firstSightingIsActive() {
        var t = IdleTracker()
        #expect(t.update(key: key, cpuSec: 10, now: 0) == 0)
    }

    @Test("flat CPU time accumulates idle time")
    func flatCpuAccumulatesIdle() {
        var t = IdleTracker()
        _ = t.update(key: key, cpuSec: 10, now: 0)
        #expect(t.update(key: key, cpuSec: 10, now: 180) == 180)
        #expect(t.update(key: key, cpuSec: 10, now: 900) == 900)
    }

    @Test("background timer drip (~0.1% of a core) still counts as idle")
    func smallDripStaysIdle() {
        var t = IdleTracker()
        _ = t.update(key: key, cpuSec: 0, now: 0)
        var cpu = 0.0
        var idle = 0.0
        for step in 1...20 {
            cpu += 180 * 0.001
            idle = t.update(key: key, cpuSec: cpu, now: Double(step) * 180)
        }
        #expect(idle == 3600)
    }

    @Test("sustained work resets idle to zero")
    func busyResetsIdle() {
        var t = IdleTracker()
        _ = t.update(key: key, cpuSec: 0, now: 0)
        #expect(t.update(key: key, cpuSec: 90, now: 180) == 0)
    }

    /// Regression: a daemon idle for hours then picked up by a CI build must be seen as busy
    /// within one scan interval, otherwise autopilot may kill it mid-build.
    @Test("burst after a long idle period resets idle within one interval")
    func burstAfterLongIdleResets() {
        var t = IdleTracker()
        _ = t.update(key: key, cpuSec: 0, now: 0)
        #expect(t.update(key: key, cpuSec: 1, now: 7200) == 7200)   // 2h, tiny drip
        #expect(t.update(key: key, cpuSec: 21, now: 7380) == 0)     // 20s CPU in 3 min
    }

    @Test("a reused pid with a new start time is tracked as a new process")
    func pidReuseStartsFresh() {
        var t = IdleTracker()
        _ = t.update(key: key, cpuSec: 5, now: 0)
        #expect(t.update(key: key, cpuSec: 5, now: 600) == 600)
        let reused = IdleTracker.Key(pid: 42, startAbs: 9999)
        #expect(t.update(key: reused, cpuSec: 0, now: 600) == 0)
    }

    @Test("prune drops processes that were not seen")
    func pruneDropsUnseen() {
        var t = IdleTracker()
        let other = IdleTracker.Key(pid: 7, startAbs: 1)
        _ = t.update(key: key, cpuSec: 0, now: 0)
        _ = t.update(key: other, cpuSec: 0, now: 0)
        t.prune(keeping: [key])
        #expect(t.trackedCount == 1)
    }
}
