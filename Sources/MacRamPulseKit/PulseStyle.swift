import SwiftUI

// MARK: - Design tokens (v5.7, Liquid Glass)

/// The popover follows the macOS 26 / iOS 26 design language: controls float on Liquid Glass above
/// the content, corners are concentric, numerals are rounded, and a soft tint follows the state word.
/// On macOS 13–15 the same views fall back to translucent fills.
enum PulseStyle {
    static let heroRadius: CGFloat = 20
    static let cardRadius: CGFloat = 16
    static let rowRadius: CGFloat = 11
    static let chipRadius: CGFloat = 7

    /// Liquid Glass is composited by the window server, so offscreen renders (README screenshots,
    /// tests) come out blank; they switch to the translucent fallback instead.
    static var glassEnabled = true

    static func color(_ level: ComfortLevel) -> Color {
        switch level {
        case .breezy: return .teal
        case .easy: return .green
        case .okay: return .yellow
        case .strained: return .orange
        case .onFire: return .red
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26+, a translucent card before.
    @ViewBuilder
    func glassCard(_ radius: CGFloat = PulseStyle.cardRadius, tint: Color? = nil) -> some View {
        if #available(macOS 26, *), PulseStyle.glassEnabled {
            // a sheer wash of the colour on top of the glass keeps the tint visible on any backdrop
            self
                .background(tint?.opacity(0.16) ?? .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.45)) } ?? .regular, in: .rect(cornerRadius: radius))
        } else {
            self
                .background(tint?.opacity(0.14) ?? Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
    }

    /// Glass button on macOS 26+, bordered before.
    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26, *), PulseStyle.glassEnabled {
            if prominent { self.buttonStyle(.glassProminent).tint(tint) } else { self.buttonStyle(.glass).tint(tint) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent).tint(tint) } else { self.buttonStyle(.bordered).tint(tint) }
        }
    }

    /// Content rows sit *under* the glass layer: a quiet fill, no glass (per the HIG).
    func contentRow(_ radius: CGFloat = PulseStyle.rowRadius) -> some View {
        background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Small parts

/// Capsule label: "41개", "유휴 데몬", "3.2 GB".
struct Chip: View {
    let text: String
    var color: Color? = nil
    var size: CGFloat = 9.5

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((color ?? .primary).opacity(color == nil ? 0.08 : 0.16), in: Capsule())
            .foregroundStyle(color ?? .secondary)
            .lineLimit(1)
    }
}

/// Thin capsule gauge. Drawn by hand (not ProgressView) so its tint also shows
/// when the popover's window is inactive.
struct MeterBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                .frame(width: fraction > 0 ? max(height, geo.size.width * CGFloat(min(1.0, fraction))) : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .frame(height: height)
    }
}

/// The menu bar's Mac mini, drawn large. Plays only while visible and only if motion is wanted.
struct AnimatedMacMini: View {
    let level: ComfortLevel
    let animate: Bool
    var scale: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let paused = !animate || reduceMotion
        TimelineView(.animation(minimumInterval: 1 / MenuBarIcon.fps(level), paused: paused)) { context in
            let frame = PopoverIconClock.frame(for: level, at: context.date.timeIntervalSinceReferenceDate, reduceMotion: paused)
            Image(nsImage: MenuBarIcon.image(level, frame: frame, of: MenuBarIcon.frameCount(level)))
                .resizable()
                .interpolation(.high)
                .frame(width: MenuBarIcon.size.width * scale, height: MenuBarIcon.size.height * scale)
        }
        .accessibilityLabel("메모리 상태: \(level.word)")
    }
}

/// "지금 내 맥은 — 쾌적": the state word, why, and the two numbers behind it.
struct ComfortHeroCard: View {
    let reading: ComfortReading
    let usedPct: Int
    let swapGB: Double
    let animate: Bool

    private var color: Color { PulseStyle.color(reading.level) }

    var body: some View {
        HStack(spacing: 14) {
            AnimatedMacMini(level: reading.level, animate: animate)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("지금 내 맥은")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(reading.level.word)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(color)
                        .contentTransition(.numericText())
                }
                Text(reading.reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Chip(text: "메모리 \(usedPct)%")
                    Chip(text: String(format: "SSD로 밀려남 %.1f GB", swapGB), color: swapGB > 0 ? color : nil)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 86)
        .glassCard(PulseStyle.heroRadius, tint: color)
        .animation(.spring(duration: 0.45), value: reading.level)
    }
}
