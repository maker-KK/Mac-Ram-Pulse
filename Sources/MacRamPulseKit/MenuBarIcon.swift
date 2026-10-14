import Cocoa

/// A little Mac mini with a face, drawn in code and animated per comfort level:
/// breezy = eyes closed in bliss, bobbing in a breeze, blushing · easy = content smile, blinks, a sparkle ·
/// okay = neutral face, heat shimmer · strained = worried brows, wavy mouth, a sweat drop ·
/// onFire = wide eyes, open mouth, shaking, and the Mac mini is on fire.
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

    static func image(_ level: ComfortLevel, frame: Int, of count: Int) -> NSImage {
        let t = Double(frame) / Double(max(1, count))     // loop phase 0..<1
        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let dx = shakeX(level, frame: frame)
            let dy = bobY(level, t: t)
            switch level {
            case .breezy: drawBreeze(cg, t)
            case .easy: drawSparkle(cg, t)
            case .okay: drawWaves(cg, t, rows: [5.5], alpha: 0.5, color: .systemOrange)
            case .strained:
                drawWaves(cg, t * 2, rows: [3, 6], alpha: 0.8, color: .systemOrange)
                drawSweat(cg, t, dx: dx)
            case .onFire:
                drawFlames(cg, t)
                drawSparks(cg, t)
            }
            drawBody(cg, level, dx: dx, dy: dy)
            drawFace(cg, level, t: t, frame: frame, dx: dx, dy: dy)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Motion

    private static func shakeX(_ level: ComfortLevel, frame: Int) -> CGFloat {
        switch level {
        case .onFire: return frame % 2 == 0 ? -0.7 : 0.7
        case .strained: return frame % 4 < 2 ? -0.25 : 0.25
        default: return 0
        }
    }

    /// Breezy floats up and down like it's napping in the wind.
    private static func bobY(_ level: ComfortLevel, t: Double) -> CGFloat {
        level == .breezy ? CGFloat(sin(2 * .pi * t)) * 0.6 : 0
    }

    // MARK: Body

    static let bodyRect = CGRect(x: 3, y: 8.5, width: 20, height: 8.5)

    private static func drawBody(_ cg: CGContext, _ level: ComfortLevel, dx: CGFloat, dy: CGFloat) {
        let body = bodyRect.offsetBy(dx: dx, dy: dy)
        let path = CGPath(roundedRect: body, cornerWidth: 2.6, cornerHeight: 2.6, transform: nil)
        // scorched when on fire, otherwise brushed silver
        let top = level == .onFire ? NSColor(srgbRed: 0.62, green: 0.50, blue: 0.48, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.87, blue: 0.90, alpha: 1)
        let bottom = level == .onFire ? NSColor(srgbRed: 0.46, green: 0.38, blue: 0.38, alpha: 1) : NSColor(srgbRed: 0.68, green: 0.70, blue: 0.75, alpha: 1)
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        let colors = [top.cgColor, bottom.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
        }
        cg.restoreGState()
        cg.addPath(path)
        cg.setStrokeColor(NSColor(srgbRed: 0.40, green: 0.42, blue: 0.47, alpha: 1).cgColor)
        cg.setLineWidth(0.8)
        cg.strokePath()
        cg.setFillColor(NSColor(white: 1, alpha: 0.45).cgColor)            // glossy top edge
        cg.fill(CGRect(x: body.minX + 2, y: body.minY + 0.7, width: body.width - 4, height: 0.7))
        cg.setFillColor(NSColor(white: 0, alpha: 0.18).cgColor)            // little feet
        cg.fill(CGRect(x: body.minX + 3, y: body.maxY, width: 3, height: 0.8))
        cg.fill(CGRect(x: body.maxX - 6, y: body.maxY, width: 3, height: 0.8))
    }

    // MARK: Face

    private static let ink = NSColor(srgbRed: 0.18, green: 0.20, blue: 0.26, alpha: 1)

    private static func drawFace(_ cg: CGContext, _ level: ComfortLevel, t: Double, frame: Int, dx: CGFloat, dy: CGFloat) {
        let body = bodyRect.offsetBy(dx: dx, dy: dy)
        let eyeY = body.minY + 3.3
        let left = CGPoint(x: body.midX - 3.6, y: eyeY), right = CGPoint(x: body.midX + 3.6, y: eyeY)
        let mouth = CGPoint(x: body.midX, y: body.minY + 6.1)
        cg.setStrokeColor(ink.cgColor)
        cg.setFillColor(ink.cgColor)
        cg.setLineCap(.round)
        cg.setLineWidth(0.9)

        switch level {
        case .breezy:
            // eyes closed in bliss: two little arches; rosy cheeks; a round smile
            happyEye(cg, at: left); happyEye(cg, at: right)
            blush(cg, at: CGPoint(x: left.x - 1.6, y: eyeY + 1.7)); blush(cg, at: CGPoint(x: right.x + 1.6, y: eyeY + 1.7))
            smile(cg, at: mouth, width: 4.2, depth: 1.5)
        case .easy:
            // content: open eyes, a blink on one frame, a soft smile
            if frame == 7 { closedEye(cg, at: left); closedEye(cg, at: right) } else { dotEye(cg, at: left); dotEye(cg, at: right) }
            smile(cg, at: mouth, width: 3.6, depth: 1.0)
        case .okay:
            // neutral: eyes glance sideways now and then, straight mouth
            let glance: CGFloat = (4...6).contains(frame) ? 0.5 : 0
            dotEye(cg, at: CGPoint(x: left.x + glance, y: left.y)); dotEye(cg, at: CGPoint(x: right.x + glance, y: right.y))
            cg.move(to: CGPoint(x: mouth.x - 1.8, y: mouth.y)); cg.addLine(to: CGPoint(x: mouth.x + 1.8, y: mouth.y)); cg.strokePath()
        case .strained:
            // worried: brows slanting up toward the middle, a wobbly mouth
            dotEye(cg, at: left); dotEye(cg, at: right)
            cg.setLineWidth(0.8)
            cg.move(to: CGPoint(x: left.x - 1.3, y: eyeY - 1.5)); cg.addLine(to: CGPoint(x: left.x + 1.0, y: eyeY - 2.3)); cg.strokePath()
            cg.move(to: CGPoint(x: right.x + 1.3, y: eyeY - 1.5)); cg.addLine(to: CGPoint(x: right.x - 1.0, y: eyeY - 2.3)); cg.strokePath()
            let wobble = CGFloat(frame % 2 == 0 ? 0.5 : -0.5)
            cg.move(to: CGPoint(x: mouth.x - 2.2, y: mouth.y))
            cg.addCurve(to: CGPoint(x: mouth.x + 2.2, y: mouth.y),
                        control1: CGPoint(x: mouth.x - 0.8, y: mouth.y + wobble), control2: CGPoint(x: mouth.x + 0.8, y: mouth.y - wobble))
            cg.strokePath()
        case .onFire:
            // panic: wide eyes with shrinking pupils, mouth wide open
            for p in [left, right] {
                cg.setFillColor(NSColor.white.cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - 1.4, y: p.y - 1.4, width: 2.8, height: 2.8))
                cg.setStrokeColor(ink.cgColor)
                cg.setLineWidth(0.6)
                cg.strokeEllipse(in: CGRect(x: p.x - 1.4, y: p.y - 1.4, width: 2.8, height: 2.8))
                let pupil: CGFloat = frame % 2 == 0 ? 1.0 : 0.7
                cg.setFillColor(ink.cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - pupil / 2, y: p.y - pupil / 2, width: pupil, height: pupil))
            }
            cg.setFillColor(ink.cgColor)
            cg.fillEllipse(in: CGRect(x: mouth.x - 1.4, y: mouth.y - 1.3, width: 2.8, height: 2.6))
        }
    }

    private static func dotEye(_ cg: CGContext, at p: CGPoint) {
        cg.fillEllipse(in: CGRect(x: p.x - 0.9, y: p.y - 0.9, width: 1.8, height: 1.8))
        cg.setFillColor(NSColor.white.cgColor)                               // catchlight
        cg.fillEllipse(in: CGRect(x: p.x - 0.1, y: p.y - 0.6, width: 0.6, height: 0.6))
        cg.setFillColor(ink.cgColor)
    }

    private static func closedEye(_ cg: CGContext, at p: CGPoint) {
        cg.move(to: CGPoint(x: p.x - 1.1, y: p.y)); cg.addLine(to: CGPoint(x: p.x + 1.1, y: p.y)); cg.strokePath()
    }

    /// An upside-down "U": the eye of someone smiling with their whole face.
    private static func happyEye(_ cg: CGContext, at p: CGPoint) {
        cg.addArc(center: CGPoint(x: p.x, y: p.y + 0.4), radius: 1.2, startAngle: .pi, endAngle: 0, clockwise: false)
        cg.strokePath()
    }

    private static func smile(_ cg: CGContext, at p: CGPoint, width: CGFloat, depth: CGFloat) {
        cg.move(to: CGPoint(x: p.x - width / 2, y: p.y - depth * 0.4))
        cg.addQuadCurve(to: CGPoint(x: p.x + width / 2, y: p.y - depth * 0.4), control: CGPoint(x: p.x, y: p.y + depth))
        cg.strokePath()
    }

    private static func blush(_ cg: CGContext, at p: CGPoint) {
        cg.setFillColor(NSColor(srgbRed: 1, green: 0.55, blue: 0.65, alpha: 0.6).cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - 1.1, y: p.y - 0.65, width: 2.2, height: 1.3))
        cg.setFillColor(ink.cgColor)
    }

    // MARK: Effects (above the body)

    private static func drawBreeze(_ cg: CGContext, _ t: Double) {
        cg.setLineCap(.round)
        cg.setLineWidth(1.1)
        for (i, y) in [1.8, 4.2, 6.6].enumerated() {
            let phase = (t + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
            let x = CGFloat(phase) * 30 - 5
            let fade = CGFloat(sin(.pi * phase))
            cg.setStrokeColor(NSColor(srgbRed: 0.25, green: 0.78, blue: 0.70, alpha: 0.9 * fade).cgColor)
            cg.move(to: CGPoint(x: x, y: y))
            cg.addQuadCurve(to: CGPoint(x: x + 6, y: y), control: CGPoint(x: x + 3, y: y - 0.8))
            cg.strokePath()
        }
        // a tiny leaf riding the wind
        let lp = (t * 0.7).truncatingRemainder(dividingBy: 1)
        let leaf = CGPoint(x: CGFloat(lp) * 32 - 4, y: 3.5 + CGFloat(sin(2 * .pi * lp * 2)) * 1.2)
        cg.setFillColor(NSColor(srgbRed: 0.35, green: 0.75, blue: 0.40, alpha: CGFloat(sin(.pi * lp))).cgColor)
        cg.fillEllipse(in: CGRect(x: leaf.x, y: leaf.y, width: 2.4, height: 1.3))
    }

    private static func drawSparkle(_ cg: CGContext, _ t: Double) {
        // two stars taking turns twinkling
        star(cg, at: CGPoint(x: 20, y: 3.5), phase: t, color: NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1), size: 3.0)
        star(cg, at: CGPoint(x: 6, y: 5), phase: t + 0.5, color: NSColor(srgbRed: 0.55, green: 0.80, blue: 1, alpha: 1), size: 2.0)
    }

    private static func star(_ cg: CGContext, at c: CGPoint, phase: Double, color: NSColor, size: CGFloat) {
        let s = CGFloat(max(0, sin(2 * .pi * phase)))                    // visible during half the loop
        guard s > 0.05 else { return }
        let r = size * s, w = 0.3 * size * s
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addLine(to: CGPoint(x: c.x + w, y: c.y - w)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
        p.addLine(to: CGPoint(x: c.x + w, y: c.y + w)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
        p.addLine(to: CGPoint(x: c.x - w, y: c.y + w)); p.addLine(to: CGPoint(x: c.x - r, y: c.y))
        p.addLine(to: CGPoint(x: c.x - w, y: c.y - w)); p.closeSubpath()
        cg.addPath(p)
        cg.setFillColor(color.cgColor)
        cg.fillPath()
    }

    private static func drawWaves(_ cg: CGContext, _ t: Double, rows: [CGFloat], alpha: CGFloat, color: NSColor) {
        cg.setLineWidth(1)
        cg.setLineCap(.round)
        cg.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        for y in rows {
            for x in stride(from: CGFloat(7), through: 19, by: 0.5) {
                let p = CGPoint(x: x, y: y + CGFloat(sin(Double(x) * 0.9 + 2 * .pi * t)) * 1.0)
                if x == 7 { cg.move(to: p) } else { cg.addLine(to: p) }
            }
            cg.strokePath()
        }
    }

    /// A drop sliding down the side of the face.
    private static func drawSweat(_ cg: CGContext, _ t: Double, dx: CGFloat) {
        let y = 7 + CGFloat(t) * 7
        cg.addPath(teardrop(cx: 24 + dx, tipY: y, height: 3.2, width: 2.2))
        cg.setFillColor(NSColor(srgbRed: 0.35, green: 0.68, blue: 1, alpha: CGFloat(1 - t * 0.5)).cgColor)
        cg.fillPath()
        cg.setFillColor(NSColor(white: 1, alpha: 0.8).cgColor)
        cg.fillEllipse(in: CGRect(x: 24 + dx - 0.6, y: y + 1.6, width: 0.6, height: 0.6))
    }

    private static func drawFlames(_ cg: CGContext, _ t: Double) {
        for (i, cx) in [7.5, 13.0, 18.5].enumerated() {
            let wobble = sin(2 * .pi * (t + Double(i) * 0.33))
            let h = CGFloat(7.0 + 2.0 * wobble)
            let lean = CGFloat(wobble) * 0.6
            cg.addPath(teardrop(cx: CGFloat(cx) + lean, tipY: 9.5 - h, height: h, width: 5.0))
            cg.setFillColor(NSColor(srgbRed: 1, green: 0.30, blue: 0.12, alpha: 0.95).cgColor)
            cg.fillPath()
            cg.addPath(teardrop(cx: CGFloat(cx) + lean * 0.5, tipY: 9.5 - h * 0.6, height: h * 0.6, width: 2.8))
            cg.setFillColor(NSColor(srgbRed: 1, green: 0.82, blue: 0.15, alpha: 1).cgColor)
            cg.fillPath()
        }
    }

    /// Embers drifting up from the flames.
    private static func drawSparks(_ cg: CGContext, _ t: Double) {
        for (i, x) in [5.0, 11.0, 16.0, 22.0].enumerated() {
            let phase = (t + Double(i) * 0.25).truncatingRemainder(dividingBy: 1)
            let y = 8 - CGFloat(phase) * 8
            cg.setFillColor(NSColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: CGFloat(1 - phase)).cgColor)
            cg.fillEllipse(in: CGRect(x: CGFloat(x) + CGFloat(sin(phase * 6)) * 0.8, y: y, width: 1.1, height: 1.1))
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
