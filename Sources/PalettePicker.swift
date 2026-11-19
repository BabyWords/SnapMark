import AppKit

/// 颜色选择板：左边一组常用色块，右边一个色盘（色相环 + 饱和度）。
/// 注意：不能只用 NSPopover —— 覆盖层窗口在 .screenSaver 层，
/// 系统弹层的层级比它低，弹出来会被盖住看不见。所以这里自绘成子视图。
final class PalettePickerView: NSView {

    var onPick: ((NSColor) -> Void)?

    /// 当前颜色（用来在色块上加白圈、在色盘上画指示点）
    var current: NSColor = Palette.colors[0] {
        didSet { needsDisplay = true }
    }

    private let swatch: CGFloat = 20
    private let gap: CGFloat = 5
    private let pad: CGFloat = 10
    private let cols = 4
    private let wheelSide: CGFloat = 96

    private var wheelImage: CGImage?
    private var wheelPixelSide: Int = 0
    private var gridRect: NSRect = .zero
    private var wheelRect: NSRect = .zero
    private var draggingWheel = false

    static var panelSize: NSSize {
        let rows = CGFloat((Palette.colors.count + 3) / 4)
        let gw: CGFloat = 4 * 20 + 3 * 5
        let gh: CGFloat = rows * 20 + (rows - 1) * 5
        let w: CGFloat = 10 * 2 + gw + 12 + 96
        let h: CGFloat = 10 * 2 + max(gh, 96)
        return NSSize(width: w, height: h)
    }

    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 布局

    private func layoutRegions() {
        let rows = CGFloat((Palette.colors.count + cols - 1) / cols)
        let gw = CGFloat(cols) * swatch + CGFloat(cols - 1) * gap
        let gh = rows * swatch + (rows - 1) * gap
        gridRect = NSRect(x: pad, y: bounds.midY - gh / 2, width: gw, height: gh)
        wheelRect = NSRect(x: gridRect.maxX + 12, y: bounds.midY - wheelSide / 2,
                           width: wheelSide, height: wheelSide)
    }

    private func swatchRect(_ index: Int) -> NSRect {
        let col = CGFloat(index % cols)
        let row = CGFloat(index / cols)
        return NSRect(x: gridRect.minX + col * (swatch + gap),
                      y: gridRect.maxY - swatch - row * (swatch + gap),
                      width: swatch, height: swatch)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        layoutRegions()

        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.14, alpha: 0.98).setFill()
        bg.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        for (i, color) in Palette.colors.enumerated() {
            let path = NSBezierPath(roundedRect: swatchRect(i), xRadius: 4, yRadius: 4)
            color.setFill()
            path.fill()
            if Palette.matches(color, current) {
                NSColor.white.setStroke()
                path.lineWidth = 2
                path.stroke()
            } else {
                // 浅色描边，避免黑色块和深色面板糊在一起
                NSColor(white: 1, alpha: 0.22).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        ensureWheel()
        if let img = wheelImage {
            ctx.draw(img, in: wheelRect)
        }
        if let p = wheelPoint(for: current) {
            let r: CGFloat = 5
            let outer = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            NSColor(white: 0, alpha: 0.6).setStroke()
            outer.lineWidth = 3
            outer.stroke()
            NSColor.white.setStroke()
            outer.lineWidth = 1.5
            outer.stroke()
        }
    }

    // MARK: 色盘位图

    private func ensureWheel() {
        let side = Int(wheelSide * (window?.backingScaleFactor ?? 2))
        guard wheelImage == nil || wheelPixelSide != side else { return }
        wheelPixelSide = side
        wheelImage = PalettePickerView.makeWheel(side: side)
    }

    private static func makeWheel(side: Int) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        let buf = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let c = Double(side) / 2
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) + 0.5 - c
                let dy = Double(y) + 0.5 - c      // 位图 y 向下
                let dist = (dx * dx + dy * dy).squareRoot()
                let i = (y * side + x) * 4
                if dist > c {
                    buf[i] = 0; buf[i+1] = 0; buf[i+2] = 0; buf[i+3] = 0
                    continue
                }
                var hue = atan2(dy, dx) / (2 * .pi)
                if hue < 0 { hue += 1 }
                let sat = min(dist / c, 1)
                let rgb = hsv(hue, sat, 1)
                // 边缘做一个像素的羽化，避免锯齿
                let alpha = min(max(c - dist, 0), 1)
                buf[i]     = UInt8((rgb.0 * 255 * alpha).rounded())
                buf[i + 1] = UInt8((rgb.1 * 255 * alpha).rounded())
                buf[i + 2] = UInt8((rgb.2 * 255 * alpha).rounded())
                buf[i + 3] = UInt8((alpha * 255).rounded())
            }
        }
        return ctx.makeImage()
    }

    private static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch i % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// 颜色在色盘上的位置（白/灰没有色相，不在盘上）
    private func wheelPoint(for color: NSColor) -> NSPoint? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s > 0.04 else { return nil }
        let r = (wheelRect.width / 2) * s
        let center = NSPoint(x: wheelRect.midX, y: wheelRect.midY)
        return NSPoint(x: center.x + cos(h * 2 * .pi) * r,
                       y: center.y - sin(h * 2 * .pi) * r)
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        layoutRegions()

        for (i, color) in Palette.colors.enumerated() where swatchRect(i).contains(p) {
            current = color
            onPick?(color)
            return
        }

        if wheelRect.contains(p) {
            draggingWheel = true
            pickWheel(at: p, finish: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingWheel else { return }
        pickWheel(at: convert(event.locationInWindow, from: nil), finish: false)
    }

    override func mouseUp(with event: NSEvent) {
        draggingWheel = false
    }

    private func pickWheel(at p: NSPoint, finish: Bool) {
        let center = NSPoint(x: wheelRect.midX, y: wheelRect.midY)
        let dx = p.x - center.x
        let dy = center.y - p.y          // 视图 y 向上，色盘位图 y 向下
        let radius = wheelRect.width / 2
        var sat = (dx * dx + dy * dy).squareRoot() / radius
        sat = min(max(sat, 0), 1)
        var hue = atan2(dy, dx) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let color = NSColor(hue: hue, saturation: sat, brightness: 1, alpha: 1)
        current = color
        onPick?(color)
    }
}

// MARK: - 箭头样式选择器

/// 箭头样式选择浮层：横向列出几种箭头样式（细/粗/渐变粗），点击选择。
/// 与色板一样自绘成子视图，避免 NSPopover 被 .screenSaver 层的覆盖窗口盖住。
final class ArrowStylePickerView: NSView {

    var onPick: ((ArrowStyle) -> Void)?

    var current: ArrowStyle = .thin {
        didSet { needsDisplay = true }
    }

    private static let cardW: CGFloat = 64
    private static let cardH: CGFloat = 40
    private static let gap: CGFloat = 6
    private static let pad: CGFloat = 8

    static var panelSize: NSSize {
        let count = CGFloat(ArrowStyle.allCases.count)
        let w = pad * 2 + count * cardW + (count - 1) * gap
        let h = pad * 2 + cardH
        return NSSize(width: w, height: h)
    }

    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func cardRect(_ index: Int) -> NSRect {
        NSRect(x: Self.pad + CGFloat(index) * (Self.cardW + Self.gap),
               y: Self.pad,
               width: Self.cardW, height: Self.cardH)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 面板背景
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.14, alpha: 0.98).setFill()
        bg.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        for (i, style) in ArrowStyle.allCases.enumerated() {
            let rect = cardRect(i)

            // 卡片背景：选中用强调色，否则用深灰
            let card = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            if style == current {
                NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
            } else {
                NSColor(calibratedWhite: 0.24, alpha: 1).setFill()
            }
            card.fill()

            // 箭头预览（白色，复用真实渲染逻辑，保证所见即所得）
            ctx.saveGState()
            ctx.clip(to: rect.insetBy(dx: 2, dy: 2))
            let a = Annotation(kind: .arrow,
                               start: CGPoint(x: rect.minX + 12, y: rect.midY),
                               end: CGPoint(x: rect.maxX - 12, y: rect.midY),
                               color: .white, lineWidth: 2.5, arrowStyle: style)
            Renderer.draw([a], in: ctx, imageScale: 1, base: nil)
            ctx.restoreGState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, style) in ArrowStyle.allCases.enumerated() where cardRect(i).contains(p) {
            current = style
            onPick?(style)
            return
        }
    }
}
