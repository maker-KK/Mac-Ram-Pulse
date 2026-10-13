import Cocoa
import SwiftUI
import Darwin

// MARK: - Side-Effect Boundary (injectable for tests)

struct MonitorEnvironment {
    var defaults: UserDefaults = .standard
    var sendSignal: (pid_t, Int32) -> Int32 = { kill($0, $1) }
    /// Asks the GUI apps among `pids` to quit normally; returns how many were asked.
    var quitGUIApps: (Set<pid_t>) -> Int = MonitorEnvironment.quitRunningApps
    /// false = no initial scan and no timers (unit tests).
    var startsAutomatically = true
    /// Runs an external command and returns its exit status and combined output.
    var runCommand: (String, [String]) -> CommandResult = MonitorEnvironment.runProcess
    /// Replaces the live libproc scan (unit tests).
    var scanOverride: (() -> [ProcSample])? = nil
    /// How long a "정리" tap stays armed before it needs to be tapped again.
    var confirmTimeout: TimeInterval = 3.5
    /// Current executable path of a pid ("" if gone).
    var currentPath: (pid_t) -> String = MonitorEnvironment.executablePath

    static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    static func runProcess(_ path: String, _ args: [String]) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return CommandResult(status: task.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func quitRunningApps(_ pids: Set<pid_t>) -> Int {
        let apps = NSWorkspace.shared.runningApplications.filter {
            pids.contains($0.processIdentifier) && $0.activationPolicy != .prohibited
        }
        apps.forEach { $0.terminate() }
        return apps.count
    }
}

struct CommandResult {
    let status: Int32
    let output: String

    var lastLine: String {
        output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

// MARK: - High-Performance Mach & Libproc System Monitor

class SystemMemoryMonitor: ObservableObject {
    static let quickRefreshInterval: TimeInterval = 6
    static let popoverRefreshInterval: TimeInterval = 3
    static let patrolInterval: TimeInterval = 180
    static let daemonIdleSec: Double = 600       // Autopilot: IDE build daemons idle >= 10 min
    static let manualIdleSec: Double = 60        // Manual bulk reclaim: idle >= 1 min
    static let codexDupeIdleSec: Double = 3600   // Opt-in: duplicate Codex MCP idle >= 60 min
    static let toastDuration: TimeInterval = 6
    static let maxLogs = 50
    static let minGroupMB = 35.0

    static let machineLabel: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let chip = String(cString: buf).replacingOccurrences(of: "Apple ", with: "")
        let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return chip.isEmpty ? "\(gb)GB" : "\(chip) \(gb)GB"
    }()

    @Published var stats = MemoryStats()
    @Published var mainTab: MainTab = .apps
    @Published var sortMode: SortMode = .swap
    @Published var searchText: String = ""
    @Published var lastActionMessage: String = "" {
        didSet { scheduleToastDismiss() }
    }
    @Published var isBusy: Bool = false
    @Published var isPopoverVisible: Bool = false
    @Published var confirmingGroupId: String? = nil

    // Autopilot Settings (Persisted)
    @Published var autoGuardEnabled: Bool = true {
        didSet { defaults.set(autoGuardEnabled, forKey: "MRP_AutoGuard") }
    }
    @Published var cleanOrphanedIDEDaemons: Bool = true {
        didSet { defaults.set(cleanOrphanedIDEDaemons, forKey: "MRP_CleanIDE") }
    }
    @Published var trimBloatedRenderers: Bool = false {
        didSet { defaults.set(trimBloatedRenderers, forKey: "MRP_TrimRenderers") }
    }
    @Published var cleanCodexDuplicateMCPs: Bool = false {
        didSet { defaults.set(cleanCodexDuplicateMCPs, forKey: "MRP_CleanCodexDupes") }
    }

    @Published var autoLogs: [String] = []
    @Published var totalSavedMB: Double = 0.0
    @Published var totalCleanCount: Int = 0

    private let scanQueue = DispatchQueue(label: "com.antigravity.MacRamPulse.scan", qos: .userInitiated)
    private let scanner = ProcessScanner()
    private var statusBarTimer: Timer?
    private var popoverTimer: Timer?
    private var patrolTimer: Timer?
    private var toastDismissWork: DispatchWorkItem?
    private var confirmWork: DispatchWorkItem?
    var onUpdateStatusTitle: ((String) -> Void)?
    private let env: MonitorEnvironment
    private var defaults: UserDefaults { env.defaults }

    /// Runs on scanQueue only.
    private func scanProcesses() -> [ProcSample] {
        env.scanOverride?() ?? scanner.scan()
    }

    init(env: MonitorEnvironment = MonitorEnvironment()) {
        self.env = env
        let ud = env.defaults
        if ud.object(forKey: "MRP_AutoGuard") != nil {
            self.autoGuardEnabled = ud.bool(forKey: "MRP_AutoGuard")
        }
        if ud.object(forKey: "MRP_CleanIDE") != nil {
            self.cleanOrphanedIDEDaemons = ud.bool(forKey: "MRP_CleanIDE")
        }
        if ud.object(forKey: "MRP_TrimRenderers") != nil {
            self.trimBloatedRenderers = ud.bool(forKey: "MRP_TrimRenderers")
        }
        self.cleanCodexDuplicateMCPs = ud.bool(forKey: "MRP_CleanCodexDupes")

        self.autoLogs = ud.stringArray(forKey: "MacRamPulse_AutoLogs") ?? []
        self.totalSavedMB = ud.double(forKey: "MacRamPulse_TotalSavedMB")
        self.totalCleanCount = ud.integer(forKey: "MacRamPulse_TotalCleanCount")

        if self.autoLogs.isEmpty {
            addLog("⚡ 네이티브 Mach/libproc 초경량 엔진 가동 (서브프로세스 0개)")
            addLog("🤖 3분 주기 안전 오토파일럿 순찰 활성화됨")
        }

        guard env.startsAutomatically else { return }

        // Initial full scan (also seeds CPU idle tracking)
        refreshFull()

        // 1. Lightweight StatusBar Timer (popover closed: Mach syscalls only)
        statusBarTimer = Timer.scheduledTimer(withTimeInterval: Self.quickRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPopoverVisible, !self.isBusy else { return }
            self.refreshQuickStatusBarOnly()
        }

        // 2. Autonomous Background Patrol
        patrolTimer = Timer.scheduledTimer(withTimeInterval: Self.patrolInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.autoGuardEnabled, !self.isBusy else { return }
            self.runAutoPatrol(manualTrigger: false)
        }
    }

    func setPopoverOpen(_ open: Bool) {
        isPopoverVisible = open
        popoverTimer?.invalidate()
        popoverTimer = nil
        if open {
            refreshFull()
            popoverTimer = Timer.scheduledTimer(withTimeInterval: Self.popoverRefreshInterval, repeats: true) { [weak self] _ in
                guard let self = self, self.isPopoverVisible, !self.isBusy else { return }
                self.refreshFull()
            }
        } else {
            disarmConfirmation()
        }
    }

    var filteredAndSortedGroups: [AppGroupMemory] {
        let base: [AppGroupMemory]
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            base = stats.groups
        } else {
            base = stats.groups.filter { $0.name.lowercased().contains(q) }
        }
        let key: (AppGroupMemory) -> Double
        switch sortMode {
        case .swap: key = { $0.swapMB }
        case .ram: key = { $0.rssMB }
        case .total: key = { $0.totalMB }
        }
        // Groups come from a Dictionary; tie-break so rows don't jump on every refresh.
        return base.sorted { a, b in
            let (ka, kb) = (key(a), key(b))
            if ka != kb { return ka > kb }
            if a.totalMB != b.totalMB { return a.totalMB > b.totalMB }
            return a.name < b.name
        }
    }

    var hasNoSearchResults: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty && filteredAndSortedGroups.isEmpty
    }

    var isToastWarning: Bool {
        ["⚠️", "⏳", "ℹ️"].contains { lastActionMessage.hasPrefix($0) }
    }

    private func scheduleToastDismiss() {
        toastDismissWork?.cancel()
        guard !lastActionMessage.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.lastActionMessage = "" }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration, execute: work)
    }

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Applied immediately when called on the main thread, otherwise hopped onto it.
    func addLog(_ message: String) {
        let entry = "[\(Self.logTimeFormatter.string(from: Date()))] \(message)"
        let apply = {
            self.autoLogs = Array(([entry] + self.autoLogs).prefix(Self.maxLogs))
            self.defaults.set(self.autoLogs, forKey: "MacRamPulse_AutoLogs")
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func clearLogs() {
        autoLogs.removeAll()
        addLog("📜 활동 기록이 초기화되었습니다.")
    }

    static func statusTitle(usedPct: Int, swapGB: Double, pressure: Int) -> String {
        let dot: String
        if pressure >= 4 || swapGB > 9.0 || usedPct > 88 {
            dot = "🔴"
        } else if pressure >= 2 || swapGB > 5.0 || usedPct > 75 {
            dot = "🟡"
        } else {
            dot = "🟢"
        }
        return String(format: "%@ %d%% · Swp %.1fG", dot, usedPct, swapGB)
    }

    private func publishTitle(_ title: String) {
        DispatchQueue.main.async { self.onUpdateStatusTitle?(title) }
    }

    // MARK: - Zero-Subprocess Mach Kernel Quick Update (0.02 ms)

    func refreshQuickStatusBarOnly() {
        var s = MemoryStats()
        Self.readVM(into: &s)
        publishTitle(Self.statusTitle(usedPct: s.usedPercent, swapGB: s.swapUsedMB / 1024.0, pressure: s.vmPressureLevel))
    }

    // MARK: - Full Native Scan (libproc)

    func refreshFull() {
        scanQueue.async {
            let newStats = self.collectNativeStats()
            DispatchQueue.main.async {
                self.stats = newStats
                self.onUpdateStatusTitle?(Self.statusTitle(
                    usedPct: newStats.usedPercent,
                    swapGB: newStats.swapUsedMB / 1024.0,
                    pressure: newStats.vmPressureLevel
                ))
            }
        }
    }

    /// Runs on scanQueue only.
    private func collectNativeStats() -> MemoryStats {
        let t0 = CFAbsoluteTimeGetCurrent()
        var s = MemoryStats()
        Self.readVM(into: &s)
        Self.readDisks(into: &s)
        s.offloadTargets = Self.readOffloadTargets()
        let grouped = Self.buildGroups(scanProcesses())
        s.groups = grouped.groups
        s.reclaimableSwapMB = grouped.reclaimableMB
        s.scanDurationMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        return s
    }

    static func readVM(into s: inout MemoryStats) {
        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = Double(vm_kernel_page_size)
        let gbDiv = 1024.0 * 1024.0 * 1024.0
        s.totalGB = Double(ProcessInfo.processInfo.physicalMemory) / gbDiv

        if kr == KERN_SUCCESS {
            s.activeGB = (Double(vmStat.active_count) * pageSize) / gbDiv
            s.wiredGB = (Double(vmStat.wire_count) * pageSize) / gbDiv
            s.compressedGB = (Double(vmStat.compressor_page_count) * pageSize) / gbDiv
            s.usedGB = s.activeGB + s.wiredGB + s.compressedGB
            s.freeGB = max(0, s.totalGB - s.usedGB)
            s.usedPercent = Int(min(100, max(0, (s.usedGB / max(1, s.totalGB)) * 100.0)))
        }

        var memLevel: Int32 = 50
        var lSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_level", &memLevel, &lSize, nil, 0)
        s.kernelFreeLevel = Int(memLevel)

        var pressure: Int32 = 1
        var pSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pSize, nil, 0)
        s.vmPressureLevel = Int(pressure)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            s.swapTotalMB = Double(swap.xsu_total) / (1024.0 * 1024.0)
            s.swapUsedMB = Double(swap.xsu_used) / (1024.0 * 1024.0)
        }
    }

    static func readDisks(into s: inout MemoryStats) {
        let gbDiv = 1024.0 * 1024.0 * 1024.0
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let freeSpace = attrs[.systemFreeSize] as? NSNumber,
           let totalSpace = attrs[.systemSize] as? NSNumber {
            s.internalFreeGB = freeSpace.doubleValue / gbDiv
            s.internalTotalGB = totalSpace.doubleValue / gbDiv
            s.internalUsedPct = Int(((s.internalTotalGB - s.internalFreeGB) / max(1, s.internalTotalGB)) * 100.0)
        }
        if let extAttrs = try? FileManager.default.attributesOfFileSystem(forPath: "/Volumes/ExternalSSD"),
           let extFree = extAttrs[.systemFreeSize] as? NSNumber,
           let extTotal = extAttrs[.systemSize] as? NSNumber {
            s.externalFreeGB = extFree.doubleValue / gbDiv
            s.externalTotalGB = extTotal.doubleValue / gbDiv
            s.externalUsedPct = Int(((s.externalTotalGB - s.externalFreeGB) / max(1, s.externalTotalGB)) * 100.0)
        }
    }

    static func readOffloadTargets() -> [OffloadTarget] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rawTargets: [(String, String, String, String, String)] = [
            ("cache-uv", "Python UV 캐시 (~/.cache/uv)", "Python 패키지 및 가상환경 캐시 외장 SSD 분산", "\(home)/.cache/uv", "16.0 GB"),
            ("gradle", "Gradle 빌드 & 데몬 캐시 (~/.gradle)", "Java/Kotlin 빌드 메모리 매핑(mmap) 외장 분산", "\(home)/.gradle", "8.8 GB"),
            ("android", "Android SDK & AVD 캐시 (~/.android)", "에뮬레이터 및 SDK 캐시 외장 분산", "\(home)/.android", "7.6 GB"),
            ("xcode-derived", "Xcode DerivedData 빌드 캐시", "Xcode 인덱싱/빌드 아티팩트 외장 분산", "\(home)/Library/Developer/Xcode/DerivedData", "7.4 GB"),
            ("npm", "Node / NPM 글로벌 캐시 (~/.npm)", "Node/MCP 패키지 읽기 I/O 외장 분산", "\(home)/.npm", "2.1 GB")
        ]
        let fm = FileManager.default
        return rawTargets.map { (id, title, desc, path, sizeStr) in
            var isSymlink = false
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let type = attrs[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                isSymlink = true
            }
            return OffloadTarget(
                id: id,
                title: title,
                desc: desc,
                sourcePath: path,
                offloadName: id,
                estimatedSize: sizeStr,
                isOffloaded: isSymlink,
                exists: fm.fileExists(atPath: path) || isSymlink
            )
        }
    }

    static func buildGroups(_ samples: [ProcSample]) -> (groups: [AppGroupMemory], reclaimableMB: Double) {
        struct Acc {
            let info: GroupInfo
            var rssMB = 0.0, swapMB = 0.0, totalMB = 0.0, idleMB = 0.0
            var pids: [pid_t] = []
            var idlePids: [pid_t] = []
            var pidPaths: [pid_t: String] = [:]
        }
        var dict: [String: Acc] = [:]
        var reclaimMB = 0.0

        for s in samples {
            guard let info = ProcessClassifier.classify(s) else { continue }
            var acc = dict[info.name] ?? Acc(info: info)
            acc.rssMB += s.rssMB
            acc.swapMB += max(0, s.footprintMB - s.rssMB)
            acc.totalMB += s.footprintMB
            acc.pids.append(s.pid)
            acc.pidPaths[s.pid] = s.path
            if s.idleSec >= manualIdleSec {
                acc.idlePids.append(s.pid)
                acc.idleMB += s.footprintMB
            }
            if info.isReclaimable { reclaimMB += s.footprintMB }
            dict[info.name] = acc
        }

        let groups = dict.values
            .filter { $0.totalMB >= minGroupMB }
            .map { a in
                AppGroupMemory(
                    name: a.info.name,
                    icon: a.info.icon,
                    rssMB: a.rssMB,
                    swapMB: a.swapMB,
                    totalMB: a.totalMB,
                    processCount: a.pids.count,
                    pids: a.pids,
                    idlePids: a.idlePids,
                    idleMB: a.idleMB,
                    isProtected: a.info.isProtected,
                    isReclaimableDaemon: a.info.isReclaimable,
                    pidPaths: a.pidPaths
                )
            }
        return (groups, reclaimMB)
    }

    // MARK: - Safe Autonomous Patrol (idle-aware)

    struct PatrolSettings {
        let cleanIDE: Bool
        let trimRenderers: Bool
        let cleanCodexDupes: Bool
    }

    struct PatrolVictim {
        let sample: ProcSample
        let label: String
    }

    static func patrolVictims(_ samples: [ProcSample], _ cfg: PatrolSettings) -> [PatrolVictim] {
        let studioOpen = samples.contains { $0.path.contains("Android Studio.app/Contents/MacOS/studio") }
        let xcodeOpen = samples.contains { $0.path.contains("Xcode.app/Contents/MacOS/Xcode") }
        var victims: [PatrolVictim] = []

        for s in samples {
            let lower = s.path.lowercased()
            let idleDaemon = s.ageSec > 300 && s.idleSec >= daemonIdleSec

            // Rule 1: Android Studio JBR java (Gradle/Kotlin daemon) left behind after Studio quit, idle >= 10 min
            if cfg.cleanIDE && !studioOpen && idleDaemon && lower.contains("android studio.app/contents/jbr") {
                victims.append(PatrolVictim(sample: s, label: "종료된 Android Studio의 유휴 Java/Gradle 데몬"))
            // Rule 2: Orphaned Dart/Flutter daemon (ppid == 1, > 350MB, idle >= 10 min)
            } else if cfg.cleanIDE && s.ppid == 1 && idleDaemon && s.footprintMB > 350 &&
                        (lower.contains("dartaotruntime") || lower.contains("flutter_tester")) {
                victims.append(PatrolVictim(sample: s, label: "고아 Flutter/Dart 데몬"))
            // Rule 3: SourceKitService while Xcode is closed, idle >= 10 min (respawns on demand)
            } else if cfg.cleanIDE && !xcodeOpen && idleDaemon && lower.contains("sourcekitservice") {
                victims.append(PatrolVictim(sample: s, label: "미사용 SourceKit"))
            // Rule 4 (opt-in): single leaking renderer > 2GB
            } else if cfg.trimRenderers && s.footprintMB > 2048 &&
                        (lower.contains("aside helper (renderer)") || lower.contains("notion helper (renderer)")) {
                victims.append(PatrolVictim(sample: s, label: "과다 누수 렌더러(\(Int(s.footprintMB))MB)"))
            }
        }

        // Rule 5 (opt-in): stale duplicate Codex MCP servers, newest of each set kept
        if cfg.cleanCodexDupes {
            victims += ProcessClassifier.idleCodexDuplicates(samples, minIdleSec: codexDupeIdleSec)
                .map { PatrolVictim(sample: $0, label: "Codex 유휴 중복 MCP 서버") }
        }
        return victims
    }

    func runAutoPatrol(manualTrigger: Bool = false) {
        let cfg = PatrolSettings(
            cleanIDE: cleanOrphanedIDEDaemons,
            trimRenderers: trimBloatedRenderers,
            cleanCodexDupes: cleanCodexDuplicateMCPs
        )
        let wantsFullRefresh = isPopoverVisible || manualTrigger

        scanQueue.async {
            let victims = Self.patrolVictims(self.scanProcesses(), cfg)
            victims.forEach { _ = self.env.sendSignal($0.sample.pid, SIGTERM) }
            let freedMB = victims.reduce(0) { $0 + $1.sample.footprintMB }

            DispatchQueue.main.async {
                if !victims.isEmpty {
                    let unique = Array(Set(victims.map { $0.label })).sorted().joined(separator: ", ")
                    let msg = String(format: "🧹 자동 회수: %@ (%d개 · 약 %.0fMB 반환)", unique, victims.count, freedMB)
                    self.addLog(msg)
                    self.totalSavedMB += freedMB
                    self.totalCleanCount += victims.count
                    self.defaults.set(self.totalSavedMB, forKey: "MacRamPulse_TotalSavedMB")
                    self.defaults.set(self.totalCleanCount, forKey: "MacRamPulse_TotalCleanCount")
                    self.lastActionMessage = msg
                } else if manualTrigger {
                    self.addLog("✅ 순찰 완료: 정리할 유휴 고아 데몬이 없습니다.")
                    self.lastActionMessage = "✅ 모든 백그라운드 프로세스가 정상 상태입니다."
                }
                // Give SIGTERM'd processes a moment to exit before re-measuring
                let delay = victims.isEmpty ? 0 : 0.8
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if wantsFullRefresh { self.refreshFull() } else { self.refreshQuickStatusBarOnly() }
                }
            }
        }
    }

    // MARK: - User Actions

    /// Row button "정리"/"회수". Daemon rows reclaim only their idle processes; app rows are armed
    /// for `confirmTimeout` and need a second tap on "종료확인".
    func requestTerminate(_ group: AppGroupMemory) {
        guard !group.isProtected else { return }
        if group.isReclaimableDaemon {
            reclaim([group])
            return
        }
        confirmWork?.cancel()
        confirmingGroupId = group.id
        let work = DispatchWorkItem { [weak self] in
            if self?.confirmingGroupId == group.id { self?.confirmingGroupId = nil }
        }
        confirmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + env.confirmTimeout, execute: work)
    }

    /// Row button "종료확인": acts only on the row that is currently armed, and only once.
    func confirmTerminate(_ group: AppGroupMemory) {
        guard confirmingGroupId == group.id, !group.isProtected else { return }
        disarmConfirmation()
        terminateGroup(group)
    }

    private func disarmConfirmation() {
        confirmWork?.cancel()
        confirmWork = nil
        confirmingGroupId = nil
    }

    /// SIGTERM only pids that still run the executable seen at scan time (pids get reused).
    /// Returns how many pids were skipped.
    @discardableResult
    private func signalIfUnchanged(_ pids: [pid_t], in group: AppGroupMemory) -> Int {
        var skipped = 0
        for pid in pids {
            if let seen = group.pidPaths[pid], env.currentPath(pid) != seen {
                skipped += 1
                continue
            }
            _ = env.sendSignal(pid, SIGTERM)
        }
        return skipped
    }

    /// GUI apps get a normal Quit (they can save state; helpers exit with them).
    /// Groups without a GUI app (daemons, MCP servers) get SIGTERM.
    func terminateGroup(_ group: AppGroupMemory) {
        guard !group.isProtected else { return }
        let quitCount = env.quitGUIApps(Set(group.pids))
        if quitCount == 0 {
            signalIfUnchanged(group.pids, in: group)
        }
        confirmingGroupId = nil
        let savedStr = String(format: "%.1fGB", group.totalMB / 1024.0)
        let verb = quitCount == 0 ? "정리 완료" : "종료 요청"
        let msg = "'\(group.name)' \(verb) (약 \(savedStr) 반환)"
        addLog("🖐️ " + msg)
        lastActionMessage = "✅ " + msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.refreshFull()
        }
    }

    /// Bulk reclaim only touches daemons idle for >= manualIdleSec, so a running build is never cut off.
    func reclaimIdleDaemonsNow() {
        reclaim(stats.groups.filter { $0.isReclaimableDaemon && !$0.isProtected })
    }

    private func reclaim(_ targets: [AppGroupMemory]) {
        let idleCount = targets.reduce(0) { $0 + $1.idlePids.count }
        let busyCount = targets.reduce(0) { $0 + $1.pids.count } - idleCount
        guard idleCount > 0 else {
            lastActionMessage = busyCount > 0
                ? "⏳ 빌드 데몬 \(busyCount)개가 작업 중이라 건너뛰었습니다."
                : "✅ 현재 점유 중인 유휴 빌드 데몬(Java/Dart)이 없습니다."
            return
        }
        let skipped = targets.reduce(0) { $0 + signalIfUnchanged($1.idlePids, in: $1) }
        let freedMB = targets.reduce(0) { $0 + $1.idleMB }
        var msg = String(format: "🔥 유휴 빌드 데몬 %d개 회수 완료 (약 %.1fGB 반환)", idleCount - skipped, freedMB / 1024.0)
        if busyCount > 0 { msg += " · 작업 중 \(busyCount)개 유지" }
        addLog(msg)
        lastActionMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.refreshFull()
        }
    }

    /// Runs a command off the main thread, then reports on the main thread and refreshes.
    private func runCommandInBackground(_ path: String, _ args: [String], completion: @escaping (CommandResult) -> Void) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.env.runCommand(path, args)
            DispatchQueue.main.async {
                self.isBusy = false
                completion(result)
                self.refreshFull()
            }
        }
    }

    func purgePhysicalRAMCache() {
        guard !isBusy else { return }
        lastActionMessage = "💧 macOS 물리 RAM 비활성 캐시(purge) 비우기 요청 중..."
        runCommandInBackground("/usr/bin/osascript",
                               ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]) { result in
            if result.status == 0 {
                self.addLog("💧 물리 RAM 비활성 캐시(Purge) 강제 비우기 완료")
                self.lastActionMessage = "✅ 물리 RAM 비활성 캐시 비우기 완료!"
            } else if result.output.contains("-128") {   // admin prompt cancelled
                self.lastActionMessage = "ℹ️ 캐시 비우기가 취소되었습니다."
            } else {
                self.lastActionMessage = "⚠️ 캐시 비우기 실패: \(result.lastLine.suffix(60))"
            }
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// offload.sh exits 0 on success and when the folder is already linked.
    func offloadToExternalSSD(_ target: OffloadTarget) {
        guard !target.isOffloaded, !isBusy else { return }
        isBusy = true
        lastActionMessage = "🔎 '\(target.title)' 사용 중인 프로세스 확인 중..."
        scanQueue.async {
            let blockers = OffloadSafety.blockers(for: target, in: self.scanProcesses())
            DispatchQueue.main.async {
                self.isBusy = false
                guard blockers.isEmpty else {
                    self.lastActionMessage = "⚠️ 사용 중이라 이전 보류: \(blockers.prefix(3).joined(separator: ", ")) 종료 후 다시 시도"
                    return
                }
                self.runOffload(target)
            }
        }
    }

    private func runOffload(_ target: OffloadTarget) {
        lastActionMessage = "🚀 '\(target.title)' 외장 SSD 이전 중..."
        runCommandInBackground("/bin/zsh",
                               ["/Volumes/ExternalSSD/MacOffload/offload.sh", target.sourcePath, target.offloadName]) { result in
            if result.status == 0 {
                self.addLog("🚀 '\(target.title)' 외장 SSD 심볼릭 링크 가속 완료")
                self.lastActionMessage = "✅ '\(target.title)' 외장 SSD 연결 완료!"
            } else {
                self.lastActionMessage = "⚠️ 이전 확인 필요: \(result.lastLine.suffix(60))"
            }
        }
    }

    func cleanUnavailableSimulators() {
        guard !isBusy else { return }
        lastActionMessage = "🧹 미사용 구버전 iOS 시뮬레이터 정리 중..."
        runCommandInBackground("/usr/bin/xcrun", ["simctl", "delete", "unavailable"]) { result in
            if result.status == 0 {
                self.addLog("🧹 내장 SSD 미사용 iOS 시뮬레이터 캐시 정리 완료")
                self.lastActionMessage = "✅ 미사용 iOS 시뮬레이터 캐시 정리 완료!"
            } else {
                self.lastActionMessage = "⚠️ 시뮬레이터 정리 실패: \(result.lastLine.suffix(60))"
            }
        }
    }
}
