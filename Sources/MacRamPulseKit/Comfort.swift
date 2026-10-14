import Foundation

// MARK: - How the Mac feels, in one word

/// Five steps from "breezy" to "on fire". Higher raw value = worse.
enum ComfortLevel: Int, CaseIterable, Comparable {
    case breezy, easy, okay, strained, onFire

    static func < (a: ComfortLevel, b: ComfortLevel) -> Bool { a.rawValue < b.rawValue }

    var word: String {
        switch self {
        case .breezy: return "쾌적"
        case .easy: return "여유"
        case .okay: return "보통"
        case .strained: return "버거움"
        case .onFire: return "위험"
        }
    }

    var emoji: String {
        switch self {
        case .breezy: return "🍃"
        case .easy: return "🙂"
        case .okay: return "😐"
        case .strained: return "😓"
        case .onFire: return "🔥"
        }
    }
}

/// What the kernel tells us, plus the swap-in rate measured between two readings.
struct ComfortInputs {
    var pressure: Int          // kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical
    var freePercent: Int       // kern.memorystatus_level
    var swapUsedGB: Double
    var ramGB: Double
    var swapInMBps: Double     // pages read back from SSD — what actually makes a Mac stutter
}

struct ComfortReading: Equatable {
    let level: ComfortLevel
    let score: Int
    let reason: String
}

enum ComfortAssessor {
    /// Score thresholds for breezy / easy / okay / strained; anything above is onFire.
    static let levelCeilings = [8, 20, 35, 55]

    static func assess(_ i: ComfortInputs) -> ComfortReading {
        let pressure = i.pressure >= 4 ? 70 : i.pressure >= 2 ? 35 : 0
        let swapIn = step(i.swapInMBps, [(0.5, 0), (2, 8), (8, 18), (25, 30)], above: 45)
        let swap = swapPoints(swapGB: i.swapUsedGB, ramGB: i.ramGB)
        let free = i.freePercent >= 40 ? 0 : i.freePercent >= 25 ? 6 : i.freePercent >= 15 ? 14 : 24
        let score = pressure + swapIn + swap + free

        let level = ComfortLevel(rawValue: levelCeilings.firstIndex { score < $0 } ?? 4)!
        let parts = [
            (pressure, "macOS가 메모리 부족을 알리고 있어요"),
            (swapIn, "SSD에서 메모리를 계속 다시 읽어 오고 있어요"),
            (swap, "SSD로 밀려난 메모리가 많아요"),
            (free, "남은 메모리가 적어요"),
        ]
        let top = parts.max { $0.0 < $1.0 }!
        let reason = top.0 >= 8 ? top.1 : "메모리가 넉넉해요"
        return ComfortReading(level: level, score: score, reason: reason)
    }

    /// Swap relative to RAM: a 20GB swap means something different on 8GB and on 64GB.
    static func swapPoints(swapGB: Double, ramGB: Double) -> Int {
        let ratio = ramGB > 0 ? swapGB / ramGB : 0
        return step(ratio, [(0.05, 0), (0.2, 5), (0.4, 12), (0.6, 20)], above: 28)
    }

    /// Label for the swap card, on the same scale as the state word so the two never disagree.
    static func swapLabel(swapGB: Double, ramGB: Double) -> String {
        switch swapPoints(swapGB: swapGB, ramGB: ramGB) {
        case 0: return "거의 없음"
        case 5: return "조금"
        case 12: return "많음"
        default: return "높음"
        }
    }

    /// Points for the first band `value` falls under, else `above`.
    private static func step(_ value: Double, _ bands: [(Double, Int)], above: Int) -> Int {
        bands.first { value < $0.0 }?.1 ?? above
    }

    /// MB/s read back from swap between two cumulative `swapins` page counters.
    static func swapInRate(previousPages: UInt64, pages: UInt64, pageSize: UInt64, seconds: Double) -> Double {
        guard seconds > 0, pages >= previousPages else { return 0 }   // counter reset → no reading
        return Double((pages - previousPages) * pageSize) / 1_048_576 / seconds
    }
}

/// Gets worse at once (you want to know), gets better only after it holds for a second reading,
/// so the menu bar doesn't flicker on a boundary.
struct ComfortTracker {
    static let readingsToImprove = 2
    private(set) var level: ComfortLevel?
    private var pending: ComfortLevel?
    private var pendingCount = 0

    mutating func update(_ new: ComfortLevel) -> ComfortLevel {
        guard let current = level, new < current else {
            level = new
            pending = nil
            return new
        }
        if pending == new { pendingCount += 1 } else { pending = new; pendingCount = 1 }
        if pendingCount >= Self.readingsToImprove {
            level = new
            pending = nil
        }
        return level!
    }
}

// MARK: - Large icon in the popover

/// Which frame the popover's big Mac mini shows at a given time; a still first frame under Reduce Motion.
enum PopoverIconClock {
    static func frame(for level: ComfortLevel, at time: TimeInterval, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return 0 }
        return Int(time * MenuBarIcon.fps(level)) % MenuBarIcon.frameCount(level)
    }
}

// MARK: - Menu bar text

enum MenuBarMode: String, CaseIterable {
    case status = "상태"
    case iconOnly = "아이콘만"
    case numbers = "숫자"
}

enum MenuBarText {
    static func text(_ reading: ComfortReading, mode: MenuBarMode, usedPct: Int, swapGB: Double) -> String {
        switch mode {
        case .status: return reading.level.word
        case .iconOnly: return ""
        case .numbers: return String(format: "%d%% · Swp %.1fG", usedPct, swapGB)
        }
    }

    static func tooltip(_ reading: ComfortReading, usedPct: Int, swapGB: Double) -> String {
        String(format: "%@ %@ — %@\n메모리 %d%% · SSD로 밀려난 메모리 %.1fGB",
               reading.level.emoji, reading.level.word, reading.reason, usedPct, swapGB)
    }
}
