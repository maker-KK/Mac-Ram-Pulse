import Cocoa

/// A tiny Mac mini drawn in code, animated per comfort level:
/// breezy = a breeze drifts past · easy = a sparkle · okay = heat shimmer ·
/// strained = heat waves and a sweat drop · onFire = the Mac mini is on fire.
enum MenuBarIcon {
    static let size = NSSize(width: 26, height: 18)

    struct Animation {
        let frames: [NSImage]
        let fps: Double
    }

    /// Frames are drawn once per level and reused (main thread only).
    private static var cache: [ComfortLevel: Animation] = [:]
    private static var bitmapCache: [String: [CGImage]] = [:]

    /// The same frames pre-rendered to bitmaps, for Core Animation to flip without the app redrawing.
    static func bitmapFrames(for level: ComfortLevel, scale: CGFloat) -> [CGImage] {
        let key = "\(level.rawValue)@\(scale)"
        if let cached = bitmapCache[key] { return cached }
        let frames = animation(for: level).frames.compactMap { image -> CGImage? in
            var rect = NSRect(origin: .zero, size: size)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                       pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep else { return image.cgImage(forProposedRect: &rect, context: nil, hints: nil) }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }
        bitmapCache[key] = frames
        return frames
    }

    /// Transparent image that reserves the icon's space in the status item.
    static let placeholder: NSImage = {
        let image = NSImage(size: size)
        image.isTemplate = false
        return image
    }()

    static func animation(for level: ComfortLevel) -> Animation {
        if let cached = cache[level] { return cached }
        let count = frameCount(level)
        let anim = Animation(frames: (0..<count).map { image(level, frame: $0, of: count) }, fps: fps(level))
        cache[level] = anim
        return anim
    }

    static func frameCount(_ level: ComfortLevel) -> Int {
        switch level {
        case .breezy, .easy, .okay: return 12
        case .strained: return 8
        case .onFire: return 6
        }
    }

    /// Calm states move slowly; the worse it gets, the more urgent the motion.
    static func fps(_ level: ComfortLevel) -> Double {
        switch level {
        case .breezy: return 4
        case .easy: return 3
        case .okay: return 4
        case .strained: return 8
        case .onFire: return 10
        }
    }

    static let ledColor: [ComfortLevel: NSColor] = [
        .breezy: NSColor(srgbRed: 0.20, green: 0.80, blue: 0.45, alpha: 1),
        .easy: NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        .okay: NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        .strained: NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        .onFire: NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
    ]

    static func image(_ level: ComfortLevel, frame: Int, of count: Int) -> NSImage {
        let t = Double(frame) / Double(max(1, count))     // loop phase 0..<1
        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            switch level {
            case .breezy: drawBreeze(cg, t)
            case .easy: drawSparkle(cg, t)
            case .okay: drawWaves(cg, t, rows: [6.5], alpha: 0.55, color: .systemOrange)
            case .strained:
                drawWaves(cg, t * 2, rows: [4, 7.5], alpha: 0.85, color: .systemOrange)
                drawSweat(cg, t)
            case .onFire: drawFlames(cg, t)
            }
            let shake: CGFloat = level == .onFire ? (frame % 2 == 0 ? -0.6 : 0.6) : 0
            drawBody(cg, dx: shake)
            drawLED(cg, dx: shake, color: ledColor[level]!, alpha: ledAlpha(level, t: t, frame: frame))
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func ledAlpha(_ level: ComfortLevel, t: Double, frame: Int) -> CGFloat {
        switch level {
        case .breezy: return CGFloat(0.55 + 0.45 * (0.5 + 0.5 * sin(2 * .pi * t)))   // slow breathing
        case .easy, .okay: return 1
        case .strained, .onFire: return frame % 2 == 0 ? 1 : 0.35                      // blinking
        }
    }

    // MARK: Drawing

    private static func drawBody(_ cg: CGContext, dx: CGFloat) {
        let body = CGRect(x: 3 + dx, y: 11, width: 20, height: 5.5)
        cg.addPath(CGPath(roundedRect: body, cornerWidth: 1.8, cornerHeight: 1.8, transform: nil))
        cg.setFillColor(NSColor(srgbRed: 0.68, green: 0.70, blue: 0.74, alpha: 1).cgColor)
        cg.setStrokeColor(NSColor(srgbRed: 0.38, green: 0.41, blue: 0.46, alpha: 1).cgColor)
        cg.setLineWidth(0.8)
        cg.drawPath(using: .fillStroke)
        cg.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor)            // top highlight
        cg.fill(CGRect(x: 4.5 + dx, y: 11.6, width: 17, height: 0.8))
    }

    private static func drawLED(_ cg: CGContext, dx: CGFloat, color: NSColor, alpha: CGFloat) {
        cg.setFillColor(color.withAlphaComponent(alpha).cgColor)
        cg.fillEllipse(in: CGRect(x: 5.3 + dx, y: 13.2, width: 2.2, height: 2.2))
    }

    private static func drawBreeze(_ cg: CGContext, _ t: Double) {
        cg.setLineCap(.round)
        cg.setLineWidth(1.2)
        for (i, y) in [2.5, 5.5, 8.5].enumerated() {
            let phase = (t + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
            let x = CGFloat(phase) * 30 - 5
            let fade = CGFloat(sin(.pi * phase))
            cg.setStrokeColor(NSColor(srgbRed: 0.25, green: 0.78, blue: 0.70, alpha: 0.9 * fade).cgColor)
            cg.move(to: CGPoint(x: x, y: y))
            cg.addLine(to: CGPoint(x: x + 6, y: y))
            cg.strokePath()
        }
    }

    private static func drawSparkle(_ cg: CGContext, _ t: Double) {
        let s = CGFloat(max(0, sin(2 * .pi * t)))                    // twinkles during half the loop
        guard s > 0.05 else { return }
        let c = CGPoint(x: 19, y: 5)
        let r = 3.2 * s, w = 0.9 * s
        let star = CGMutablePath()
        star.move(to: CGPoint(x: c.x, y: c.y - r))
        star.addLine(to: CGPoint(x: c.x + w, y: c.y - w))
        star.addLine(to: CGPoint(x: c.x + r, y: c.y))
        star.addLine(to: CGPoint(x: c.x + w, y: c.y + w))
        star.addLine(to: CGPoint(x: c.x, y: c.y + r))
        star.addLine(to: CGPoint(x: c.x - w, y: c.y + w))
        star.addLine(to: CGPoint(x: c.x - r, y: c.y))
        star.addLine(to: CGPoint(x: c.x - w, y: c.y - w))
        star.closeSubpath()
        cg.addPath(star)
        cg.setFillColor(NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1).cgColor)
        cg.fillPath()
    }

    private static func drawWaves(_ cg: CGContext, _ t: Double, rows: [CGFloat], alpha: CGFloat, color: NSColor) {
        cg.setLineWidth(1)
        cg.setLineCap(.round)
        cg.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        for y in rows {
            for x in stride(from: CGFloat(7), through: 19, by: 0.5) {
                let p = CGPoint(x: x, y: y + CGFloat(sin(Double(x) * 0.9 + 2 * .pi * t)) * 1.1)
                if x == 7 { cg.move(to: p) } else { cg.addLine(to: p) }
            }
            cg.strokePath()
        }
    }

    private static func drawSweat(_ cg: CGContext, _ t: Double) {
        let y = 3 + CGFloat(t) * 7
        let drop = teardrop(cx: 23.5, tipY: y, height: 3.4, width: 2.4)
        cg.addPath(drop)
        cg.setFillColor(NSColor(srgbRed: 0.35, green: 0.68, blue: 1, alpha: CGFloat(1 - t * 0.6)).cgColor)
        cg.fillPath()
    }

    private static func drawFlames(_ cg: CGContext, _ t: Double) {
        for (i, cx) in [8.0, 13.0, 18.0].enumerated() {
            let wobble = sin(2 * .pi * (t + Double(i) * 0.33))
            let h = CGFloat(7.5 + 2.5 * wobble)
            cg.addPath(teardrop(cx: CGFloat(cx), tipY: 12 - h, height: h, width: 5.2))
            cg.setFillColor(NSColor(srgbRed: 1, green: 0.27, blue: 0.13, alpha: 0.95).cgColor)
            cg.fillPath()
            cg.addPath(teardrop(cx: CGFloat(cx), tipY: 12 - h * 0.62, height: h * 0.62, width: 3))
            cg.setFillColor(NSColor(srgbRed: 1, green: 0.80, blue: 0.10, alpha: 1).cgColor)
            cg.fillPath()
        }
    }

    /// Pointed at the top (`tipY`), round at the bottom.
    private static func teardrop(cx: CGFloat, tipY: CGFloat, height: CGFloat, width: CGFloat) -> CGPath {
        let base = tipY + height
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx, y: tipY))
        p.addQuadCurve(to: CGPoint(x: cx + width / 2, y: base - width / 2), control: CGPoint(x: cx + width * 0.55, y: tipY + height * 0.45))
        p.addArc(center: CGPoint(x: cx, y: base - width / 2), radius: width / 2, startAngle: 0, endAngle: .pi, clockwise: false)
        p.addQuadCurve(to: CGPoint(x: cx, y: tipY), control: CGPoint(x: cx - width * 0.55, y: tipY + height * 0.45))
        p.closeSubpath()
        return p
    }
}
