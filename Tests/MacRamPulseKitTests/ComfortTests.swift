import AppKit
import Foundation
import Testing
@testable import MacRamPulseKit

func inputs(pressure: Int = 1, free: Int = 50, swapGB: Double = 0, ramGB: Double = 24, rate: Double = 0) -> ComfortInputs {
    ComfortInputs(pressure: pressure, freePercent: free, swapUsedGB: swapGB, ramGB: ramGB, swapInMBps: rate)
}

@Suite("Comfort — one-word state")
struct ComfortAssessorTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        let pressure: Int, free: Int, swapGB: Double, rate: Double
        let level: ComfortLevel
        let reason: String
        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(label: "idle, plenty of memory", pressure: 1, free: 60, swapGB: 0.5, rate: 0,
             level: .breezy, reason: "메모리가 넉넉해요"),
        Case(label: "right after quitting ChatGPT (4.4GB swap left, nothing read back)", pressure: 1, free: 45, swapGB: 4.4, rate: 0.2,
             level: .breezy, reason: "메모리가 넉넉해요"),
        Case(label: "a little swapping", pressure: 1, free: 45, swapGB: 2, rate: 1,
             level: .easy, reason: "SSD에서 메모리를 계속 다시 읽어 오고 있어요"),
        Case(label: "getting tight", pressure: 1, free: 30, swapGB: 8, rate: 1,
             level: .okay, reason: "SSD로 밀려난 메모리가 많아요"),
        Case(label: "this morning: 18.9GB swap, reading back", pressure: 1, free: 45, swapGB: 18.9, rate: 5,
             level: .strained, reason: "SSD로 밀려난 메모리가 많아요"),
        Case(label: "heavy swap storm with a warning", pressure: 2, free: 20, swapGB: 15, rate: 30,
             level: .onFire, reason: "SSD에서 메모리를 계속 다시 읽어 오고 있어요"),
        Case(label: "kernel says critical", pressure: 4, free: 50, swapGB: 0, rate: 0,
             level: .onFire, reason: "macOS가 메모리 부족을 알리고 있어요"),
    ]

    @Test("real-world situations map to the right word", arguments: cases)
    func situations(_ c: Case) {
        let r = ComfortAssessor.assess(inputs(pressure: c.pressure, free: c.free, swapGB: c.swapGB, rate: c.rate))
        #expect(r.level == c.level, "score \(r.score)")
        #expect(r.reason == c.reason)
    }

    /// Making any single input worse must never make the word better.
    @Test("worse inputs never give a better word")
    func monotonic() {
        let pressures = [1, 2, 4], frees = [60, 30, 20, 5], swaps = [0.0, 3, 8, 13, 20], rates = [0.0, 1, 5, 20, 50]
        for p in pressures { for f in frees { for s in swaps { for r in rates {
            let base = ComfortAssessor.assess(inputs(pressure: p, free: f, swapGB: s, rate: r)).level
            let worse = [
                inputs(pressure: min(4, p * 2), free: f, swapGB: s, rate: r),
                inputs(pressure: p, free: max(0, f - 10), swapGB: s, rate: r),
                inputs(pressure: p, free: f, swapGB: s + 5, rate: r),
                inputs(pressure: p, free: f, swapGB: s, rate: r + 10),
            ]
            for w in worse { #expect(ComfortAssessor.assess(w).level >= base) }
        } } } }
    }

    @Test("every level is reachable")
    func allLevelsReachable() {
        let seen = Set(Self.cases.map(\.level))
        #expect(seen == Set(ComfortLevel.allCases))
    }

    @Test("swap-in rate from the cumulative counter", arguments: [
        (UInt64(0), UInt64(1280), 2.0, 10.0),     // 1280 pages × 16KB over 2s = 10 MB/s
        (UInt64(5000), UInt64(5000), 6.0, 0.0),   // nothing read back
        (UInt64(9000), UInt64(10), 6.0, 0.0),     // counter reset (reboot) → no reading
        (UInt64(0), UInt64(1000), 0.0, 0.0),      // no elapsed time
    ])
    func swapInRate(prev: UInt64, now: UInt64, seconds: Double, mbps: Double) {
        #expect(abs(ComfortAssessor.swapInRate(previousPages: prev, pages: now, pageSize: 16_384, seconds: seconds) - mbps) < 0.001)
    }
}

@Suite("Comfort — no flicker")
struct ComfortTrackerTests {
    @Test("the first reading is shown as is")
    func first() {
        var t = ComfortTracker()
        #expect(t.update(.okay) == .okay)
    }

    @Test("getting worse shows at once")
    func worseImmediately() {
        var t = ComfortTracker()
        _ = t.update(.easy)
        #expect(t.update(.onFire) == .onFire)
    }

    @Test("getting better needs a second reading")
    func betterNeedsConfirmation() {
        var t = ComfortTracker()
        _ = t.update(.strained)
        #expect(t.update(.easy) == .strained)
        #expect(t.update(.easy) == .easy)
    }

    @Test("bouncing on a boundary does not flicker")
    func boundaryBounce() {
        var t = ComfortTracker()
        _ = t.update(.okay)
        var shown: [ComfortLevel] = []
        for l in [ComfortLevel.easy, .okay, .easy, .okay, .easy, .okay] { shown.append(t.update(l)) }
        #expect(Set(shown) == [.okay])
    }

    @Test("a different better reading restarts the wait")
    func differentBetterReading() {
        var t = ComfortTracker()
        _ = t.update(.onFire)
        #expect(t.update(.okay) == .onFire)
        #expect(t.update(.easy) == .onFire)
        #expect(t.update(.easy) == .easy)
    }
}

@Suite("Comfort — menu bar text")
struct MenuBarTextTests {
    let reading = ComfortReading(level: .strained, score: 46, reason: "SSD로 밀려난 메모리가 많아요")

    @Test("each display mode", arguments: [(MenuBarMode.status, "버거움"), (.iconOnly, ""), (.numbers, "71% · Swp 18.9G")])
    func modes(mode: MenuBarMode, text: String) {
        #expect(MenuBarText.text(reading, mode: mode, usedPct: 71, swapGB: 18.9) == text)
    }

    @Test("the tooltip explains the word in plain language")
    func tooltip() {
        let tip = MenuBarText.tooltip(reading, usedPct: 71, swapGB: 18.9)
        #expect(tip.contains("버거움"))
        #expect(tip.contains("SSD로 밀려난 메모리가 많아요"))
        #expect(tip.contains("18.9GB"))
    }
}

@Suite("Comfort — menu bar icon", .serialized)
@MainActor
struct MenuBarIconTests {
    func bitmap(_ image: NSImage) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 52, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = MenuBarIcon.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: MenuBarIcon.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Fraction of pixels in the top (effects) area matching a colour test.
    func share(_ rep: NSBitmapImageRep, _ match: (NSColor) -> Bool) -> Double {
        var hits = 0, total = 0
        for x in 0..<rep.pixelsWide { for y in 0..<14 {
            total += 1
            if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.3, match(c) { hits += 1 }
        } }
        return Double(hits) / Double(total)
    }

    @Test("every level animates with several distinct frames", arguments: ComfortLevel.allCases)
    func framesDiffer(level: ComfortLevel) {
        let anim = MenuBarIcon.animation(for: level)
        #expect(anim.frames.count == MenuBarIcon.frameCount(level))
        #expect(anim.frames.allSatisfy { $0.size == MenuBarIcon.size && !$0.isTemplate })
        let pixels = Set(anim.frames.map { bitmap($0).tiffRepresentation! })
        #expect(pixels.count > 1)
    }

    @Test("the worse the state, the faster the motion")
    func urgencyGrows() {
        #expect(MenuBarIcon.fps(.onFire) > MenuBarIcon.fps(.strained))
        #expect(MenuBarIcon.fps(.strained) > MenuBarIcon.fps(.okay))
        #expect(ComfortLevel.allCases.allSatisfy { MenuBarIcon.fps($0) <= 10 })   // keeps CPU near zero
    }

    @Test("on fire really shows flames; breezy shows none")
    func flames() {
        let fiery: (NSColor) -> Bool = { c in
            let rgb = c.usingColorSpace(.deviceRGB)!
            return rgb.redComponent > 0.8 && rgb.blueComponent < 0.3
        }
        #expect(share(bitmap(MenuBarIcon.animation(for: .onFire).frames[0]), fiery) > 0.05)
        #expect(share(bitmap(MenuBarIcon.animation(for: .breezy).frames[0]), fiery) == 0)
    }

    @Test("frames are drawn once and reused")
    func cached() {
        let a = MenuBarIcon.animation(for: .okay).frames[0]
        let b = MenuBarIcon.animation(for: .okay).frames[0]
        #expect(a === b)
    }

    @Test("still icon when motion is reduced, animation is off, or displays sleep")
    func whenToAnimate() {
        #expect(MenuBarIconPlayer.shouldAnimate(wants: true, reduceMotion: false, displaysAsleep: false, frames: 12))
        #expect(!MenuBarIconPlayer.shouldAnimate(wants: false, reduceMotion: false, displaysAsleep: false, frames: 12))
        #expect(!MenuBarIconPlayer.shouldAnimate(wants: true, reduceMotion: true, displaysAsleep: false, frames: 12))
        #expect(!MenuBarIconPlayer.shouldAnimate(wants: true, reduceMotion: false, displaysAsleep: true, frames: 12))
    }

    @Test("drawing every frame of every level stays cheap")
    func drawingIsCheap() {
        let start = Date()
        for level in ComfortLevel.allCases {
            let count = MenuBarIcon.frameCount(level)
            for f in 0..<count { _ = bitmap(MenuBarIcon.image(level, frame: f, of: count)) }
        }
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
}

@Suite("Comfort — monitor", .serialized)
@MainActor
struct ComfortMonitorTests {
    func stats(swapGB: Double, swapInPages: UInt64, pressure: Int = 1, free: Int = 45) -> MemoryStats {
        var s = MemoryStats()
        s.totalGB = 24
        s.usedPercent = 71
        s.swapUsedMB = swapGB * 1024
        s.swapInPages = swapInPages
        s.pageSize = 16_384
        s.vmPressureLevel = pressure
        s.kernelFreeLevel = free
        return s
    }

    @Test("the swap-in rate is measured between two readings")
    func rateBetweenReadings() {
        let m = Spy().makeMonitor()
        m.publishStatus(stats(swapGB: 18.9, swapInPages: 0), now: 0)
        #expect(m.comfort.level == .okay)                                   // 28 points: no rate yet
        m.publishStatus(stats(swapGB: 18.9, swapInPages: 1920), now: 6)    // 30MB in 6s = 5MB/s
        #expect(m.comfort.level == .strained)
    }

    @Test("the menu bar gets the word, the level, the animation flag and a tooltip")
    func callbacks() {
        let m = Spy().makeMonitor()
        var title = "", level: ComfortLevel?, animate: Bool?, tip = ""
        m.onUpdateStatusTitle = { title = $0 }
        m.onUpdateComfort = { level = $0; animate = $1; tip = $2 }
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 0), now: 0)
        #expect(title == "쾌적")
        #expect(level == .breezy && animate == true)
        #expect(tip.contains("넉넉"))
    }

    @Test("changing the display mode updates the menu bar at once and persists")
    func modeChange() {
        let spy = Spy()
        let m = spy.makeMonitor()
        var title = ""
        m.onUpdateStatusTitle = { title = $0 }
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 0), now: 0)
        m.menuBarMode = .numbers
        #expect(title == "71% · Swp 0.5G")
        m.menuBarMode = .iconOnly
        #expect(title == "")
        #expect(spy.makeMonitor().menuBarMode == .iconOnly)
    }

    @Test("turning animation off reaches the menu bar and persists")
    func animationToggle() {
        let spy = Spy()
        let m = spy.makeMonitor()
        var animate: Bool?
        m.onUpdateComfort = { _, a, _ in animate = a }
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 0), now: 0)
        m.menuBarAnimation = false
        #expect(animate == false)
        #expect(spy.makeMonitor().menuBarAnimation == false)
    }

    @Test("defaults: status word with animation")
    func defaults() {
        let m = Spy().makeMonitor()
        #expect(m.menuBarMode == .status && m.menuBarAnimation)
    }

    @Test("recovery is shown only after it holds")
    func recoveryHolds() {
        let m = Spy().makeMonitor()
        m.publishStatus(stats(swapGB: 20, swapInPages: 0, pressure: 4), now: 0)
        #expect(m.comfort.level == .onFire)
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 0), now: 6)
        #expect(m.comfort.level == .onFire)
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 0), now: 12)
        #expect(m.comfort.level == .breezy)
    }

    @Test("a live quick refresh publishes a comfort level on the main thread")
    func liveQuickRefresh() async throws {
        let m = Spy().makeMonitor()
        var onMain = false
        m.onUpdateComfort = { _, _, _ in onMain = Thread.isMainThread }
        m.refreshQuickStatusBarOnly()
        for _ in 0..<50 where !onMain { try await Task.sleep(for: .milliseconds(20)) }
        #expect(onMain)
    }
}

/// Plays the animation in a real (temporary) menu bar item and reads back what Core Animation shows.
@Suite("Comfort — live menu bar playback", .serialized)
@MainActor
struct MenuBarPlaybackTests {
    @Test("frames cycle on screen; turning animation off leaves a still frame")
    func playsAndStops() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        button.imagePosition = .imageLeft
        button.title = " 위험"
        let player = MenuBarIconPlayer()
        player.button = button
        player.show(.onFire, animate: true)
        try await Task.sleep(for: .milliseconds(300))

        let layer = try #require(button.layer?.sublayers?.first { $0.animation(forKey: "comfort") != nil })
        #expect(layer.frame.size == MenuBarIcon.size)
        var seen = Set<ObjectIdentifier>()
        for _ in 0..<20 {
            if let c = layer.presentation()?.contents { seen.insert(ObjectIdentifier(c as AnyObject)) }
            try await Task.sleep(for: .milliseconds(70))
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(seen.count <= 1)
        } else {
            #expect(seen.count >= 4)
        }

        player.show(.breezy, animate: false)
        #expect((layer.animationKeys() ?? []).isEmpty)
        #expect(layer.contents != nil)
    }
}
