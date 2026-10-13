import Cocoa
import SwiftUI
import Darwin

// MARK: - AppDelegate & StatusBar Controller

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    var monitor = SystemMemoryMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🟢 측정중..."
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        monitor.onUpdateStatusTitle = { [weak self] title in
            self?.statusItem.button?.title = title
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
