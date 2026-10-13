import Foundation
import Darwin

// MARK: - Enums & Data Models

enum MainTab: String, CaseIterable {
    case apps = "📊 앱별 리소스"
    case autopilot = "🤖 무인 자동관리"
    case ssdBoost = "💾 외장SSD 버퍼"
}

enum SortMode: String, CaseIterable {
    case swap = "🔥 스왑순"
    case ram = "🧠 물리RAM순"
    case total = "📊 총합순"
}

struct AppGroupMemory: Identifiable {
    var id: String { name }
    let name: String
    let icon: String
    let rssMB: Double        // Resident physical RAM
    let swapMB: Double       // Compressed + SSD Swap (Footprint - RSS)
    let totalMB: Double      // Physical Footprint (ri_phys_footprint)
    let processCount: Int
    let pids: [pid_t]
    let idlePids: [pid_t]    // No CPU activity for >= SystemMemoryMonitor.manualIdleSec
    let idleMB: Double
    let isProtected: Bool
    let isReclaimableDaemon: Bool
    /// Executable path per pid at scan time, to avoid signalling a reused pid.
    var pidPaths: [pid_t: String] = [:]

    /// "유휴 데몬" badge: a reclaimable daemon row whose every process is idle.
    var showsIdleBadge: Bool { isReclaimableDaemon && !pids.isEmpty && idlePids.count == pids.count }
}

struct OffloadTarget: Identifiable {
    let id: String
    let title: String
    let desc: String
    let sourcePath: String
    let offloadName: String
    let estimatedSize: String
    var isOffloaded: Bool
    var exists: Bool
}

struct MemoryStats {
    var totalGB: Double = 24.0
    var activeGB: Double = 0.0
    var wiredGB: Double = 0.0
    var compressedGB: Double = 0.0
    var usedGB: Double = 0.0
    var freeGB: Double = 0.0
    var usedPercent: Int = 0

    var kernelFreeLevel: Int = 50      // kern.memorystatus_level (0..100%)
    var vmPressureLevel: Int = 1       // 1 = Normal, 2 = Warn, 4 = Critical

    var swapUsedMB: Double = 0.0
    var swapTotalMB: Double = 0.0

    var internalFreeGB: Double = 0.0
    var internalTotalGB: Double = 460.0
    var internalUsedPct: Int = 0
    var externalFreeGB: Double = 0.0
    var externalTotalGB: Double = 931.0
    var externalUsedPct: Int = 0

    var scanDurationMs: Double = 0.0
    var groups: [AppGroupMemory] = []
    var reclaimableSwapMB: Double = 0.0
    var offloadTargets: [OffloadTarget] = []
}
