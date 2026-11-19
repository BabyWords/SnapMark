import AppKit

// MARK: - 工具

enum Tool: Int, CaseIterable {
    case select, arrow, rect, ellipse, pen, text, mosaic, recognize

    /// 工具栏里实际展示的工具
    static let visible: [Tool] = [.select, .arrow, .rect, .ellipse, .pen, .text, .mosaic, .recognize]

    var symbols: [String] {
        switch self {
        case .select:  return ["cursorarrow"]
        case .arrow:   return ["arrow.up.right"]
        case .rect:    return ["rectangle"]
        case .ellipse: return ["circle"]
        case .pen:     return ["scribble.variable", "pencil", "pencil.tip"]
        case .text:    return ["textformat"]
        case .mosaic:  return ["squareshape.split.3x3", "circle.grid.3x3.fill", "aqi.medium"]
        case .recognize: return ["text.viewfinder", "text.magnifyingglass", "doc.text.viewfinder"]
        }
    }

    var title: String {
        switch self {
        case .select:  return "选择区域"
        case .arrow:   return "箭头"
        case .rect:    return "矩形"
        case .ellipse: return "椭圆"
        case .pen:     return "画笔"
        case .text:    return "文字"
        case .mosaic:  return "马赛克"
        case .recognize: return "识别文字"
        }
    }

    var annotationKind: Annotation.Kind {
        switch self {
        case .arrow:   return .arrow
        case .rect:    return .rect
        case .ellipse: return .ellipse
        case .pen:     return .pen
        case .text:    return .text
        case .mosaic:  return .mosaic
        case .recognize: return .text
        case .select:  return .rect
        }
    }
}

/// 箭头样式：细箭头、粗箭头、渐变粗箭头（锥形，从细到粗）。
enum ArrowStyle: Int, CaseIterable {
    case thin
    case thick
    case tapered

    var title: String {
        switch self {
        case .thin:    return "细箭头"
        case .thick:   return "粗箭头"
        case .tapered: return "渐变箭头"
        }
    }
}

enum Palette {
    static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemMint, .systemTeal, .systemCyan, .systemBlue,
        .systemIndigo, .systemPurple, .systemPink, .systemBrown,
        .white, .lightGray, .darkGray, .black
    ]

    static func matches(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.deviceRGB), let y = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.02
            && abs(x.greenComponent - y.greenComponent) < 0.02
            && abs(x.blueComponent - y.blueComponent) < 0.02
    }
}

// MARK: - 标注模型

struct Annotation {
    enum Kind { case arrow, rect, ellipse, pen, text, mosaic }

    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var lineWidth: CGFloat = 3
    var arrowStyle: ArrowStyle = .thin
    var text: String?
    var fontSize: CGFloat = 18

    /// end 默认与 start 相同。
    /// 之前 end 的默认值是 (0,0)：按下鼠标那一刻还没拖出第二个点，就会画出一条
    /// 从落点指向屏幕左下角的"假箭头"，被选框裁一刀后表现为"线闪一下"。
    init(kind: Kind,
         start: CGPoint,
         end: CGPoint? = nil,
         points: [CGPoint] = [],
         color: NSColor,
         lineWidth: CGFloat = 3,
         arrowStyle: ArrowStyle = .thin,
         text: String? = nil,
         fontSize: CGFloat = 18) {
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.arrowStyle = arrowStyle
        self.text = text
        self.fontSize = fontSize
    }

    static func rectBetween(_ a: CGPoint, _ b: CGPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var bounds: NSRect {
        switch kind {
        case .pen:
            guard let first = points.first else { return .zero }
            var r = NSRect(origin: first, size: .zero)
            for p in points { r = r.union(NSRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lineWidth, dy: -lineWidth)
        default:
            return Annotation.rectBetween(start, end).insetBy(dx: -lineWidth * 3, dy: -lineWidth * 3)
        }
    }

    /// 整体平移（移动选区时标注跟着走）
    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        guard dx != 0 || dy != 0 else { return self }
        var a = self
        a.start = CGPoint(x: start.x + dx, y: start.y + dy)
        a.end = CGPoint(x: end.x + dx, y: end.y + dy)
        a.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return a
    }
}

// MARK: - 渲染

enum Renderer {

    /// 在"点"坐标系中绘制标注（调用方负责把 CTM 缩放到点空间）
    static func draw(_ list: [Annotation], in ctx: CGContext, imageScale: CGFloat, base: CGImage?) {
        guard !list.isEmpty else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for a in list { drawOne(a, in: ctx, imageScale: imageScale, base: base) }
        ctx.restoreGState()
    }

    private static func drawOne(_ a: Annotation, in ctx: CGContext, imageScale: CGFloat, base: CGImage?) {
        let color = a.color.cgColor
        let r = Annotation.rectBetween(a.start, a.end)

        switch a.kind {
        case .rect:
            guard r.width > 0.5, r.height > 0.5 else { return }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.stroke(r)

        case .ellipse:
            guard r.width > 0.5, r.height > 0.5 else { return }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokeEllipse(in: r)

        case .arrow:
            drawArrow(a, in: ctx, color: color)

        case .pen:
            guard a.points.count > 1 else {
                if let p = a.points.first {
                    ctx.setFillColor(color)
                    ctx.fillEllipse(in: NSRect(x: p.x - a.lineWidth / 2, y: p.y - a.lineWidth / 2,
                                              width: a.lineWidth, height: a.lineWidth))
                }
                return
            }
            let path = CGMutablePath()
            path.move(to: a.points[0])
            for p in a.points.dropFirst() { path.addLine(to: p) }
            ctx.addPath(path)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.strokePath()

        case .mosaic:
            guard let base, r.width > 1, r.height > 1 else { return }
            let pxRect = NSRect(x: r.minX * imageScale, y: r.minY * imageScale,
                                width: r.width * imageScale, height: r.height * imageScale)
            guard let pix = pixelated(base, pixelRectYUp: pxRect, blockPoints: 12 * imageScale) else { return }
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.interpolationQuality = .none
            ctx.draw(pix, in: r)
            ctx.restoreGState()

        case .text:
            guard let t = a.text, !t.isEmpty else { return }
            drawText(t, at: a.start, color: a.color, fontSize: a.fontSize, in: ctx)
        }
    }

    private static func drawArrow(_ a: Annotation, in ctx: CGContext, color: CGColor) {
        let p0 = a.start, p1 = a.end
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = hypot(dx, dy)
        guard len > 1.5 else { return }
        let angle = atan2(dy, dx)

        switch a.arrowStyle {
        case .thin:
            drawThinArrow(p0: p0, p1: p1, angle: angle, len: len, lineWidth: a.lineWidth, in: ctx, color: color)
        case .thick:
            drawThickArrow(p0: p0, p1: p1, angle: angle, len: len, lineWidth: a.lineWidth, in: ctx, color: color)
        case .tapered:
            drawTaperedArrow(p0: p0, p1: p1, angle: angle, len: len, lineWidth: a.lineWidth, in: ctx, color: color)
        }
    }

    /// 细箭头：固定线宽的箭杆 + 实心三角头（原样式）。
    private static func drawThinArrow(p0: CGPoint, p1: CGPoint, angle: CGFloat, len: CGFloat,
                                      lineWidth: CGFloat, in ctx: CGContext, color: CGColor) {
        // 箭头头部用固定尺寸（只受线宽影响），避免拖拽过程中不断变大看起来"跳动"
        let head = min(max(lineWidth * 4.5, 10), len)
        let spread: CGFloat = .pi / 7

        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)

        // 箭杆：末端略微回缩，避免从箭头尖里戳出来
        ctx.move(to: p0)
        ctx.addLine(to: CGPoint(x: p1.x - cos(angle) * head * 0.8, y: p1.y - sin(angle) * head * 0.8))
        ctx.strokePath()

        let headPath = CGMutablePath()
        headPath.move(to: p1)
        headPath.addLine(to: CGPoint(x: p1.x - cos(angle - spread) * head,
                                     y: p1.y - sin(angle - spread) * head))
        headPath.addLine(to: CGPoint(x: p1.x - cos(angle + spread) * head,
                                     y: p1.y - sin(angle + spread) * head))
        headPath.closeSubpath()
        ctx.addPath(headPath)
        ctx.fillPath()
    }

    /// 粗箭头：更粗的箭杆与更大的箭头头，强调醒目。
    private static func drawThickArrow(p0: CGPoint, p1: CGPoint, angle: CGFloat, len: CGFloat,
                                       lineWidth: CGFloat, in ctx: CGContext, color: CGColor) {
        let w = lineWidth * 2.5
        let head = min(max(w * 3.2, 14), len)
        let spread: CGFloat = .pi / 6

        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(w)

        ctx.move(to: p0)
        ctx.addLine(to: CGPoint(x: p1.x - cos(angle) * head * 0.8, y: p1.y - sin(angle) * head * 0.8))
        ctx.strokePath()

        let headPath = CGMutablePath()
        headPath.move(to: p1)
        headPath.addLine(to: CGPoint(x: p1.x - cos(angle - spread) * head,
                                     y: p1.y - sin(angle - spread) * head))
        headPath.addLine(to: CGPoint(x: p1.x - cos(angle + spread) * head,
                                     y: p1.y - sin(angle + spread) * head))
        headPath.closeSubpath()
        ctx.addPath(headPath)
        ctx.fillPath()
    }

    /// 渐变粗箭头：锥形箭杆从细到粗渐变 + 实心三角头。
    private static func drawTaperedArrow(p0: CGPoint, p1: CGPoint, angle: CGFloat, len: CGFloat,
                                         lineWidth: CGFloat, in ctx: CGContext, color: CGColor) {
        let w0 = max(lineWidth * 0.7, 1.5)   // 起点整宽（窄端）
        let w1 = lineWidth * 2.6             // 终点整宽（粗端）
        let head = min(max(lineWidth * 4.5, 13), len)
        let spread: CGFloat = .pi / 6

        let nx = -sin(angle)
        let ny = cos(angle)
        let shaftEnd = CGPoint(x: p1.x - cos(angle) * head * 0.9,
                               y: p1.y - sin(angle) * head * 0.9)

        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)

        // 锥形箭杆：起点两侧 half0、末端两侧 half1 组成的四边形，从细到粗渐变。
        let half0 = w0 / 2
        let half1 = w1 / 2
        let shaft = CGMutablePath()
        shaft.move(to: CGPoint(x: p0.x + nx * half0, y: p0.y + ny * half0))
        shaft.addLine(to: CGPoint(x: shaftEnd.x + nx * half1, y: shaftEnd.y + ny * half1))
        shaft.addLine(to: CGPoint(x: shaftEnd.x - nx * half1, y: shaftEnd.y - ny * half1))
        shaft.addLine(to: CGPoint(x: p0.x - nx * half0, y: p0.y - ny * half0))
        shaft.closeSubpath()
        ctx.addPath(shaft)
        ctx.fillPath()

        let headPath = CGMutablePath()
        headPath.move(to: p1)
        headPath.addLine(to: CGPoint(x: p1.x - cos(angle - spread) * head,
                                     y: p1.y - sin(angle - spread) * head))
        headPath.addLine(to: CGPoint(x: p1.x - cos(angle + spread) * head,
                                     y: p1.y - sin(angle + spread) * head))
        headPath.closeSubpath()
        ctx.addPath(headPath)
        ctx.fillPath()
    }

    static func textAttributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        para.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: para,
            .shadow: shadow
        ]
    }

    /// start 为文字块左上角锚点（y 轴向上），文字向下排版
    private static func drawText(_ text: String, at start: CGPoint, color: NSColor,
                                 fontSize: CGFloat, in ctx: CGContext) {
        let str = NSAttributedString(string: text, attributes: textAttributes(color: color, fontSize: fontSize))
        let maxW: CGFloat = 560
        let box = str.boundingRect(with: NSSize(width: maxW, height: 2000),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: min(ceil(box.width) + 2, maxW), height: ceil(box.height) + 2)
        let rect = NSRect(x: start.x, y: start.y - size.height, width: size.width, height: size.height)

        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        str.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 马赛克：把区域缩小再放大（最近邻），得到块状效果
    static func pixelated(_ image: CGImage, pixelRectYUp r: NSRect, blockPoints: CGFloat) -> CGImage? {
        let imgBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rr = r.intersection(imgBounds).integral
        guard rr.width >= 2, rr.height >= 2 else { return nil }

        // CGImage.cropping 使用左上角原点的像素坐标
        let crop = CGRect(x: rr.minX, y: CGFloat(image.height) - rr.maxY, width: rr.width, height: rr.height)
        guard let cropped = image.cropping(to: crop) else { return nil }

        let block = max(4, blockPoints)
        let w = max(1, Int((rr.width / block).rounded()))
        let h = max(1, Int((rr.height / block).rounded()))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let sink = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        sink.interpolationQuality = .medium
        sink.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return sink.makeImage()
    }
}

// MARK: - 合成出图

enum Compositor {
    /// selection 为点坐标（原点左下，y 轴向上）
    static func render(base: CGImage, selection: NSRect, imageScale: CGFloat,
                       annotations: [Annotation]) -> CGImage? {
        let sel = selection.intersection(NSRect(x: 0, y: 0,
                                                width: CGFloat(base.width) / imageScale,
                                                height: CGFloat(base.height) / imageScale))
        guard sel.width >= 1, sel.height >= 1 else { return nil }
        let px = NSRect(x: sel.minX * imageScale, y: sel.minY * imageScale,
                        width: sel.width * imageScale, height: sel.height * imageScale).integral
        guard px.width >= 1, px.height >= 1,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(NSRect(x: 0, y: 0, width: px.width, height: px.height))
        ctx.interpolationQuality = .high
        ctx.draw(base, in: NSRect(x: -px.minX, y: -px.minY,
                                  width: CGFloat(base.width), height: CGFloat(base.height)))

        ctx.translateBy(x: -px.minX, y: -px.minY)
        ctx.scaleBy(x: imageScale, y: imageScale)
        // 这里的 CTM 已把"绝对点坐标"映射到裁剪后的画布，故裁剪区间用 sel
        ctx.clip(to: sel)
        Renderer.draw(annotations, in: ctx, imageScale: imageScale, base: base)
        return ctx.makeImage()
    }
}
