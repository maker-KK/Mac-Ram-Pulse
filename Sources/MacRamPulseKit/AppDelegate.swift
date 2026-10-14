import Cocoa
import SwiftUI
import Darwin

// MARK: - AppDelegate & StatusBar Controller

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    var monitor = SystemMemoryMonitor()
    private let icon = MenuBarIconPlayer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = " 측정 중"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.imagePosition = .imageLeft
            button.action = #selector(togglePopover(_:))
            button.target = self
            icon.button = button
        }

        monitor.onUpdateStatusTitle = { [weak self] title in
            self?.statusItem.button?.title = title.isEmpty ? "" : " " + title
        }
        monitor.onUpdateComfort = { [weak self] level, animate, tooltip in
            self?.icon.show(level, animate: animate)
            self?.statusItem.button?.toolTip = tooltip
            self?.statusItem.button?.setAccessibilityLabel("메모리 상태: \(level.word)")
        }

        popover.contentSize = NSSize(width: 460, height: 560)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PulsePopoverView(monitor: monitor))
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            monitor.setPopoverOpen(false)
        } else {
            monitor.setPopoverOpen(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setPopoverOpen(false)
    }
}

// MARK: - Menu bar animation

/// Plays the comfort animation on the status item with Core Animation: the frames are handed to
/// the render server once and flipped there, so the app itself does no per-frame work.
/// Shows a still frame when motion is reduced, animation is off, or the displays are asleep.
final class MenuBarIconPlayer {
    weak var button: NSStatusBarButton? {
        didSet { attach() }
    }
    private let layer = CALayer()
    private var level: ComfortLevel?
    private var wantsAnimation = true
    private var displaysAsleep = false

    init() {
        layer.contentsGravity = .resizeAspect
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaysAsleep = true
            self?.restart()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaysAsleep = false
            self?.restart()
        }
        ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        }
    }

    private func attach() {
        guard let button else { return }
        button.image = MenuBarIcon.placeholder
        button.wantsLayer = true
        button.layer?.addSublayer(layer)
    }

    func show(_ newLevel: ComfortLevel, animate: Bool) {
        layoutLayer()                                   // the title may have changed the button's width
        guard newLevel != level || animate != wantsAnimation else { return }   // same state: keep playing
        level = newLevel
        wantsAnimation = animate
        restart()
    }

    static func shouldAnimate(wants: Bool, reduceMotion: Bool, displaysAsleep: Bool, frames: Int) -> Bool {
        wants && !reduceMotion && !displaysAsleep && frames > 1
    }

    private func layoutLayer() {
        guard let button, let cell = button.cell as? NSButtonCell else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = cell.imageRect(forBounds: button.bounds)
        CATransaction.commit()
    }

    private func restart() {
        guard let level, let button else { return }
        let scale = button.window?.backingScaleFactor ?? 2
        let frames = MenuBarIcon.bitmapFrames(for: level, scale: scale)
        guard let first = frames.first else { return }
        layoutLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)          // switch states instantly, no implicit fade
        layer.removeAllAnimations()
        layer.contentsScale = scale
        layer.contents = first
        CATransaction.commit()
        let animate = Self.shouldAnimate(wants: wantsAnimation,
                                         reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                         displaysAsleep: displaysAsleep, frames: frames.count)
        guard animate else { return }
        let flip = CAKeyframeAnimation(keyPath: "contents")
        flip.values = frames
        flip.calculationMode = .discrete
        flip.duration = Double(frames.count) / MenuBarIcon.fps(level)
        flip.repeatCount = .infinity
        flip.isRemovedOnCompletion = false
        layer.add(flip, forKey: "comfort")
    }
}

// MARK: - Entry Point

public enum MacRamPulseApp {
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
