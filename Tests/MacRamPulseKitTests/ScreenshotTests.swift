import AppKit
import SwiftUI
import Testing
@testable import MacRamPulseKit

/// Regenerates the README screenshots from demo data (never from the machine's real processes):
///
///     MRP_SCREENSHOTS=1 swift test --filter ScreenshotTests
@Suite("README screenshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MRP_SCREENSHOTS"] != nil, "set MRP_SCREENSHOTS=1"))
@MainActor
struct ScreenshotTests {
    static let outDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../docs/screenshots")
        .standardizedFileURL

    @Test("render popover tabs in light and dark appearance")
    func renderAll() throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        let spy = Spy()
        let monitor = spy.makeMonitor()
        Self.loadDemo(into: monitor)

        let shots: [(MainTab, String)] = [(.apps, "apps"), (.autopilot, "autopilot"), (.ssdBoost, "ssd")]
        for (tab, name) in shots {
            monitor.mainTab = tab
            for dark in [false, true] {
                let url = Self.outDir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                try Self.render(monitor, dark: dark, to: url)
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    static func render(_ monitor: SystemMemoryMonitor, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let root = PulsePopoverView(monitor: monitor)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    static func loadDemo(into m: SystemMemoryMonitor) {
        var s = MemoryStats()
        s.totalGB = 24; s.activeGB = 7.9; s.wiredGB = 3.4; s.compressedGB = 5.8
        s.usedGB = 17.1; s.freeGB = 6.9; s.usedPercent = 71
        s.kernelFreeLevel = 52; s.vmPressureLevel = 1
        s.swapUsedMB = 3.2 * 1024; s.swapTotalMB = 6 * 1024
        s.internalFreeGB = 182.4; s.internalTotalGB = 460; s.internalUsedPct = 60
        s.externalFreeGB = 687.8; s.externalTotalGB = 931; s.externalUsedPct = 26
        s.scanDurationMs = 7.4

        func g(_ name: String, _ icon: String, rss: Double, swap: Double, n: Int,
               protected: Bool = false, reclaimable: Bool = false) -> AppGroupMemory {
            AppGroupMemory(name: name, icon: icon, rssMB: rss, swapMB: swap, totalMB: rss + swap,
                           processCount: n, pids: Array(1...Int32(n)), idlePids: [], idleMB: 0,
                           isProtected: protected, isReclaimableDaemon: reclaimable)
        }
        s.groups = [
            g("Android Studio (Java/Gradle 데몬)", "☕", rss: 410, swap: 2_840, n: 3, reclaimable: true),
            g("Codex MCP·REPL 하위 서버", "🧩", rss: 640, swap: 2_310, n: 41),
            g("Google Chrome", "🌐", rss: 1_380, swap: 1_120, n: 22),
            g("Colima / Linux VM", "🐳", rss: 520, swap: 1_060, n: 4, protected: true),
            g("Claude", "🧠", rss: 1_150, swap: 640, n: 14, protected: true),
            g("Slack", "📦", rss: 610, swap: 420, n: 7),
            g("Xcode", "📦", rss: 1_240, swap: 310, n: 9),
        ]
        s.offloadTargets = [
            ("cache-uv", "Python UV 캐시 (~/.cache/uv)", "Python 패키지 및 가상환경 캐시 외장 SSD 분산", "16.0 GB", true),
            ("gradle", "Gradle 빌드 & 데몬 캐시 (~/.gradle)", "Java/Kotlin 빌드 메모리 매핑(mmap) 외장 분산", "8.8 GB", true),
            ("android", "Android SDK & AVD 캐시 (~/.android)", "에뮬레이터 및 SDK 캐시 외장 분산", "7.6 GB", false),
            ("xcode-derived", "Xcode DerivedData 빌드 캐시", "Xcode 인덱싱/빌드 아티팩트 외장 분산", "7.4 GB", true),
            ("npm", "Node / NPM 글로벌 캐시 (~/.npm)", "Node/MCP 패키지 읽기 I/O 외장 분산", "2.1 GB", false),
        ].map { id, title, desc, size, done in
            OffloadTarget(id: id, title: title, desc: desc, sourcePath: "/tmp/\(id)", offloadName: id,
                          estimatedSize: size, isOffloaded: done, exists: true)
        }
        m.stats = s
        m.totalSavedMB = 12.4 * 1024
        m.totalCleanCount = 37
        m.autoLogs = [
            "[14:21:07] 🧹 자동 회수: 종료된 Android Studio의 유휴 Java/Gradle 데몬 (2개 · 약 3184MB 반환)",
            "[13:42:51] ✅ 순찰 완료: 정리할 유휴 고아 데몬이 없습니다.",
            "[11:05:19] 🧹 자동 회수: 미사용 SourceKit (1개 · 약 612MB 반환)",
            "[09:58:02] 🔥 유휴 빌드 데몬 3개 회수 완료 (약 2.7GB 반환) · 작업 중 1개 유지",
            "[09:12:44] 🤖 3분 주기 안전 오토파일럿 순찰 활성화됨",
        ]
    }
}
