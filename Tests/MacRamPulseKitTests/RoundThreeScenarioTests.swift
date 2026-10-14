import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacRamPulseKit

/// Round 3 (v5.7): the one-word state and the animated icon in everyday situations —
/// clock jumps, sleep/wake, back-to-back refreshes, display scale, accessibility, and the
/// popover's consistency with the menu bar. Nothing real is touched.
@Suite("Round 3 — state word & icon in daily use", .serialized)
@MainActor
struct RoundThreeScenarioTests {
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

    // 1
    @Test("two refreshes a few milliseconds apart do not read a handful of pages as a swap storm")
    func backToBackRefreshes() {
        let m = Spy().makeMonitor()
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 1000), now: 100)
        #expect(m.comfort.level == .breezy)
        // opening the popover triggers a full refresh right after the quick timer fired:
        // 50 pages (0.8MB) in 20ms would be 40MB/s if taken literally
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 1050), now: 100.02)
        #expect(m.comfort.level == .breezy, "score \(m.comfort.score)")
        // the next regular reading still measures over a sensible window
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 1050), now: 106)
        #expect(m.comfort.level == .breezy)
    }

    // 2
    @Test("the clock jumping backwards (time sync) never produces a negative or infinite rate")
    func clockGoesBackwards() {
        let m = Spy().makeMonitor()
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 5000), now: 1000)
        m.publishStatus(stats(swapGB: 0.5, swapInPages: 5100), now: 900)
        #expect(m.comfort.level == .breezy)
        #expect(m.comfort.score >= 0)
    }

    // 3
    @Test("waking from a night's sleep: hours of page-ins are averaged, not shown as a storm")
    func wakeFromSleep() {
        let m = Spy().makeMonitor()
        m.publishStatus(stats(swapGB: 1, swapInPages: 0), now: 0)
        let eightHours = 8 * 3600.0
        let twoGB = UInt64(2 * 1024 * 1024 * 1024 / 16_384)
        m.publishStatus(stats(swapGB: 1, swapInPages: twoGB), now: eightHours)
        #expect(m.comfort.level == .breezy, "score \(m.comfort.score)")
    }

    // 4
    @Test("ChatGPT restarted less than an hour ago is not described as '0시간째'")
    func uptimeUnderAnHour() {
        #expect(PulsePopoverView.uptimeText(0.4) == "24분째")
        #expect(PulsePopoverView.uptimeText(1.6) == "2시간째")
        #expect(PulsePopoverView.uptimeText(58) == "2일 넘게")
    }

    // 5
    @Test("the swap card's label agrees with the state word's swap factor", arguments: [
        (0.5, "거의 없음"), (3.0, "조금"), (5.9, "많음"), (8.0, "많음"), (12.0, "높음"), (18.9, "높음"),
    ])
    func swapLabelMatchesScore(swapGB: Double, label: String) {
        #expect(ComfortAssessor.swapLabel(swapGB: swapGB, ramGB: 24) == label)
        let points = ComfortAssessor.swapPoints(swapGB: swapGB, ramGB: 24)
        #expect((label == "거의 없음") == (points == 0))
        #expect((label == "높음") == (points >= 20))
    }

    // 6
    @Test("with animation off, a level change still swaps the still frame")
    func stillFrameFollowsLevel() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        button.imagePosition = .imageLeft
        let player = MenuBarIconPlayer()
        player.button = button
        player.show(.breezy, animate: false)
        let layer = try #require(button.layer?.sublayers?.first { $0.contents != nil })
        let calm = layer.contents as AnyObject
        player.show(.onFire, animate: false)
        let fiery = layer.contents as AnyObject
        #expect(calm !== fiery)
        #expect((layer.animationKeys() ?? []).isEmpty)
    }

    // 7
    @Test("icon-only mode: the icon keeps its full size when the title is empty")
    func iconOnlyKeepsIcon() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        button.imagePosition = .imageLeft
        button.title = ""
        let player = MenuBarIconPlayer()
        player.button = button
        player.show(.okay, animate: true)
        let layer = try #require(button.layer?.sublayers?.first { $0.contents != nil })
        #expect(layer.frame.width == MenuBarIcon.size.width)
        #expect(layer.frame.height == MenuBarIcon.size.height)
        #expect(layer.frame.minX >= 0)
    }

    // 8
    @Test("a non-Retina display gets 1x bitmaps; Retina gets 2x — cached separately")
    func displayScales() {
        let one = MenuBarIcon.bitmapFrames(for: .easy, scale: 1)
        let two = MenuBarIcon.bitmapFrames(for: .easy, scale: 2)
        #expect(one.first?.width == Int(MenuBarIcon.size.width))
        #expect(two.first?.width == Int(MenuBarIcon.size.width) * 2)
        #expect(one.count == two.count)
        #expect(MenuBarIcon.bitmapFrames(for: .easy, scale: 1).first === one.first)
    }

    // 9
    @Test("every level has its own face: first frames differ pairwise")
    func distinctFaces() {
        func png(_ level: ComfortLevel) -> Data {
            let count = MenuBarIcon.frameCount(level)
            let image = MenuBarIcon.image(level, frame: 0, of: count)
            return image.tiffRepresentation!
        }
        let frames = ComfortLevel.allCases.map(png)
        for i in frames.indices { for j in frames.indices where j > i {
            #expect(frames[i] != frames[j], "\(ComfortLevel.allCases[i]) vs \(ComfortLevel.allCases[j])")
        } }
    }

    // 10
    @Test("the popover does not change height when the state word changes")
    func popoverHeightIsStable() {
        _ = NSApplication.shared
        let spy = Spy()
        let m = spy.makeMonitor()
        ScreenshotTests.loadDemo(into: m)
        var heights: Set<CGFloat> = []
        for level in ComfortLevel.allCases {
            // swap GB and kernel free % that land on each word (see ComfortAssessor's bands)
            let inputs = [ComfortLevel.breezy: (0.0, 60), .easy: (2.0, 30), .okay: (8.0, 20), .strained: (15.0, 20), .onFire: (20.0, 5)]
            let (swap, free) = inputs[level]!
            m.publishStatus(stats(swapGB: swap, swapInPages: 0, pressure: level == .onFire ? 4 : 1, free: free), now: 0)
            m.publishStatus(stats(swapGB: swap, swapInPages: 0, pressure: level == .onFire ? 4 : 1, free: free), now: 6)
            #expect(m.comfort.level == level)
            let host = NSHostingView(rootView: PulsePopoverView(monitor: m))
            heights.insert(host.fittingSize.height.rounded())
        }
        #expect(heights.count == 1, "\(heights)")
    }

    // 11 (bonus): the big icon in the popover respects Reduce Motion
    @Test("the popover's large icon stays on its first frame when motion is reduced")
    func popoverIconReduceMotion() {
        #expect(PopoverIconClock.frame(for: .onFire, at: 0.37, reduceMotion: true) == 0)
        #expect(PopoverIconClock.frame(for: .onFire, at: 0.37, reduceMotion: false) == 3)   // 10 fps
        #expect(PopoverIconClock.frame(for: .breezy, at: 100.0, reduceMotion: false) < MenuBarIcon.frameCount(.breezy))
    }
}
