import AppKit
import ImageIO

enum DemoAssets {

    /// 一张假的"屏幕画面"，用于演示与离线自检
    static func image(size: NSSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let W = CGFloat(w), H = CGFloat(h)

        // 背景
        let colors = [
            NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.16, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.20, green: 0.27, blue: 0.46, alpha: 1).cgColor
        ] as CFArray
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
        }

        // 假窗口
        let win = NSRect(x: W * 0.08, y: H * 0.12, width: W * 0.84, height: H * 0.74)
        ctx.setFillColor(NSColor(calibratedWhite: 0.11, alpha: 0.92).cgColor)
        ctx.addPath(CGPath(roundedRect: win, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()

        // 标题栏
        ctx.setFillColor(NSColor(calibratedWhite: 0.17, alpha: 1).cgColor)
        let bar = NSRect(x: win.minX, y: win.maxY - 46, width: win.width, height: 46)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()

        // 红绿灯
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: NSRect(x: win.minX + 20 + CGFloat(i) * 22, y: win.maxY - 30,
                                      width: 13, height: 13))
        }

        // 侧边栏色块
        for i in 0..<7 {
            let y = win.maxY - 90 - CGFloat(i) * 46
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: i == 1 ? 0.22 : 0.09).cgColor)
            ctx.addPath(CGPath(roundedRect: NSRect(x: win.minX + 22, y: y, width: 190, height: 32),
                               cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.fillPath()
        }

        // 右侧"照片"区域（给马赛克用）
        let photo = NSRect(x: win.maxX - 470, y: win.minY + 60, width: 420, height: 260)
        let photoColors = [
            NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.25, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.82, green: 0.20, blue: 0.42, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.20, green: 0.75, blue: 0.72, alpha: 1).cgColor
        ] as CFArray
        if let g2 = CGGradient(colorsSpace: cs, colors: photoColors, locations: [0, 0.55, 1]) {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: photo, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.clip()
            ctx.drawLinearGradient(g2, start: CGPoint(x: photo.minX, y: photo.maxY),
                                   end: CGPoint(x: photo.maxX, y: photo.minY), options: [])
            // 一些细节，让马赛克效果明显
            for i in 0..<14 {
                ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
                let bw = CGFloat(30 + (i * 37) % 90)
                ctx.fill(NSRect(x: photo.minX + CGFloat(i) * 31, y: photo.minY + CGFloat((i * 53) % 190),
                                width: bw, height: 26))
            }
            ctx.restoreGState()
        }

        // 文字
        drawText("revenue-report-final-v3.xlsx",
                 at: CGPoint(x: win.minX + 250, y: win.maxY - 34),
                 size: 26, weight: .semibold, color: NSColor(calibratedWhite: 0.92, alpha: 1), in: ctx)
        drawText("本季度营收同比增长 23.6%，主要来自企业客户续费。",
                 at: CGPoint(x: win.minX + 250, y: win.maxY - 120),
                 size: 22, weight: .regular, color: NSColor(calibratedWhite: 0.78, alpha: 1), in: ctx)
        drawText("请确认后发送给客户。",
                 at: CGPoint(x: win.minX + 250, y: win.maxY - 165),
                 size: 22, weight: .regular, color: NSColor(calibratedWhite: 0.78, alpha: 1), in: ctx)

        // 底部提示条
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.06).cgColor)
        ctx.addPath(CGPath(roundedRect: NSRect(x: W * 0.30, y: H * 0.03, width: W * 0.40, height: 54),
                           cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()

        return ctx.makeImage()
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat,
                                 weight: NSFont.Weight, color: NSColor, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        str.draw(at: point)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 覆盖所有标注类型的样例
    static func sampleAnnotations(in sel: NSRect) -> [Annotation] {
        var list: [Annotation] = []

        // 箭头
        var arrow = Annotation(kind: .arrow,
                               start: CGPoint(x: sel.minX + 40, y: sel.maxY - 60),
                               color: .systemRed)
        arrow.end = CGPoint(x: sel.minX + 300, y: sel.minY + 70)
        list.append(arrow)

        // 矩形
        var rect = Annotation(kind: .rect,
                              start: CGPoint(x: sel.minX + 330, y: sel.minY + 150),
                              color: .systemYellow)
        rect.end = CGPoint(x: sel.minX + 300 + 210, y: sel.minY + 150 + 120)
        list.append(rect)

        // 椭圆
        var ellipse = Annotation(kind: .ellipse,
                                 start: CGPoint(x: sel.minX + 60, y: sel.minY + 40),
                                 color: .systemBlue)
        ellipse.end = CGPoint(x: sel.minX + 250, y: sel.minY + 130)
        list.append(ellipse)

        // 画笔
        var pen = Annotation(kind: .pen, start: .zero, color: .systemGreen)
        pen.points = (0..<40).map { i in
            let t = CGFloat(i) / 6
            return CGPoint(x: sel.minX + 360 + t * 7, y: sel.minY + 60 + sin(t) * 26)
        }
        pen.end = pen.points.last ?? .zero
        list.append(pen)

        // 文字
        var text = Annotation(kind: .text, start: CGPoint(x: sel.minX + 30, y: sel.maxY - 20), color: .systemRed)
        text.text = "这里需要改成 26%"
        text.fontSize = 26
        list.append(text)

        // 马赛克
        var mosaic = Annotation(kind: .mosaic, start: .zero, color: .white)
        mosaic.start = CGPoint(x: sel.minX + 300, y: sel.minY + 40)
        mosaic.end = CGPoint(x: sel.minX + 480, y: sel.minY + 140)
        list.append(mosaic)

        return list
    }
}

enum SelfTest {
    private static func verifyScrollMatching() -> Bool {
        guard let source = makeScrollTestImage(width: 96, height: 320) else {
            print("SELFTEST-FAIL: scroll test image")
            return false
        }
        let cases: [(ScrollCaptureController.Axis, ScrollCaptureController.MatchDirection, String)] = [
            (.vertical, .towardEnd, "down"),
            (.vertical, .towardStart, "up"),
            (.horizontal, .towardEnd, "right"),
            (.horizontal, .towardStart, "left")
        ]

        for (axis, expectedDirection, name) in cases {
            let previousRect: CGRect
            let nextRect: CGRect
            switch (axis, expectedDirection) {
            case (.vertical, .towardEnd):
                previousRect = CGRect(x: 0, y: 0, width: 96, height: 200)
                nextRect = CGRect(x: 0, y: 80, width: 96, height: 200)
            case (.vertical, .towardStart):
                previousRect = CGRect(x: 0, y: 80, width: 96, height: 200)
                nextRect = CGRect(x: 0, y: 0, width: 96, height: 200)
            case (.horizontal, .towardEnd):
                previousRect = CGRect(x: 0, y: 0, width: 64, height: 96)
                nextRect = CGRect(x: 32, y: 0, width: 64, height: 96)
            case (.horizontal, .towardStart):
                previousRect = CGRect(x: 32, y: 0, width: 64, height: 96)
                nextRect = CGRect(x: 0, y: 0, width: 64, height: 96)
            }
            guard let previous = source.cropping(to: previousRect),
                  let next = source.cropping(to: nextRect),
                  let match = ScrollCaptureController.bestOverlap(previous: previous, next: next, axis: axis),
                  match.direction == expectedDirection,
                  abs(match.overlap - (axis == .vertical ? 120 : 32)) <= 4 else {
                print("SELFTEST-FAIL: scroll match \(name)")
                return false
            }
        }

        // Turn around and overlap the prior canvas: both placements must stay in bounds,
        // while the overall stitched extent only grows by newly revealed pixels.
        let first = ScrollCaptureController.layout(canvasOrigin: 0, canvasLength: 200,
                                                   newFrameOffset: 80, frameLength: 200)
        let reversed = ScrollCaptureController.layout(canvasOrigin: first.origin, canvasLength: first.length,
                                                      newFrameOffset: 0, frameLength: 200)
        guard first.origin == 0, first.length == 280,
              reversed.origin == 0, reversed.length == 280,
              reversed.previousDrawOffset == 0, reversed.nextDrawOffset == 0 else {
            print("SELFTEST-FAIL: scroll direction reversal layout")
            return false
        }
        return true
    }

    private static func verifyTextScrollMatching() -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 480, height: 1800,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 1800))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for line in 0..<60 {
            let text = "第\(line)行：截图正文 matching \((line * 7919) % 10007)"
            (text as NSString).draw(at: NSPoint(x: 30, y: line * 29 + 5), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let source = ctx.makeImage() else { return false }
        for shift in [0, 3, 7, 24, 57, 211, -7, -24, -211] {
            let start = 300
            guard let a = source.cropping(to: CGRect(x: 0, y: start, width: 480, height: 900)),
                  let b = source.cropping(to: CGRect(x: 0, y: start + shift, width: 480, height: 900)) else { return false }
            guard let match = ScrollCaptureController.bestOverlap(previous: a, next: b, axis: .vertical),
                  match.overlap == 900 - abs(shift),
                  shift == 0 || match.direction == (shift > 0 ? .towardEnd : .towardStart) else {
                let actual = ScrollCaptureController.bestOverlap(previous: a, next: b, axis: .vertical)
                print("SELFTEST-FAIL: white text scroll shift \(shift), got \(actual.map { "\($0.overlap)/\($0.direction == .towardEnd ? "end" : "start")" } ?? "nil")")
                return false
            }
        }
        // Identical rows produce several equally valid offsets: do not invent a large scroll.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 1800))
        ctx.setFillColor(NSColor.black.cgColor)
        for y in stride(from: 0, to: 1800, by: 30) {
            ctx.fill(CGRect(x: 30, y: y, width: 330, height: 9))
        }
        guard let periodic = ctx.makeImage(),
              let a = periodic.cropping(to: CGRect(x: 0, y: 0, width: 480, height: 900)),
              let b = periodic.cropping(to: CGRect(x: 0, y: 7, width: 480, height: 900)),
              ScrollCaptureController.bestOverlap(previous: a, next: b, axis: .vertical) == nil else {
            print("SELFTEST-FAIL: ambiguous repeated rows accepted")
            return false
        }
        print("SELFTEST: text scroll 9/9; periodic ambiguity rejected")
        return true
    }

    private static func verifyVideoGeometry() -> Bool {
        guard let geometry = VideoRecorder.captureGeometry(
            region: NSRect(x: 12.25, y: 20.5, width: 101.25, height: 50.25),
            screenSize: NSSize(width: 200, height: 120), scale: 2
        ) else {
            print("SELFTEST-FAIL: video capture geometry nil")
            return false
        }
        guard geometry.sourceRect == CGRect(x: 12.25, y: 49.25, width: 101.25, height: 50.25),
           geometry.width.isMultiple(of: 2), geometry.height.isMultiple(of: 2),
           geometry.width == 204, geometry.height == 102 else {
            print("SELFTEST-FAIL: video capture geometry")
            return false
        }
        guard let clipped = VideoRecorder.captureGeometry(
            region: NSRect(x: -10, y: 100, width: 30, height: 40),
            screenSize: NSSize(width: 200, height: 120), scale: 2
        ), clipped.sourceRect == CGRect(x: 0, y: 0, width: 20, height: 20),
           clipped.width == 40, clipped.height == 40 else {
            print("SELFTEST-FAIL: video geometry clipping")
            return false
        }
        return true
    }

    private static func makeScrollTestImage(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for y in 0..<height {
            for x in 0..<width {
                // Deterministic texture with distinct values in both axes avoids ambiguous matches.
                let value = CGFloat((x * 37 + y * 73 + (x * y) % 251) % 256) / 255
                context.setFillColor(NSColor(calibratedWhite: value, alpha: 1).cgColor)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()
    }

    static func run() {
        let pixelSize = NSSize(width: 1600, height: 1000)
        let scale: CGFloat = 2
        let pointSize = NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale)

        guard let base = DemoAssets.image(size: pixelSize) else {
            print("SELFTEST-FAIL: base image")
            return
        }
        let sel = NSRect(x: 110, y: 90, width: pointSize.width - 220, height: pointSize.height - 200)
        let list = DemoAssets.sampleAnnotations(in: sel)
        guard let out = Compositor.render(base: base, selection: sel, imageScale: scale,
                                          annotations: list) else {
            print("SELFTEST-FAIL: composite")
            return
        }
        let path = "/tmp/snapmark-selftest.png"
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         "public.png" as CFString, 1, nil) else {
            print("SELFTEST-FAIL: destination")
            return
        }
        CGImageDestinationAddImage(dest, out, nil)
        let ok = CGImageDestinationFinalize(dest)
        guard ok else {
            print("SELFTEST-FAIL: write")
            return
        }
        guard verifyScrollMatching(), verifyTextScrollMatching(), verifyVideoGeometry() else { return }
        print("SELFTEST-OK \(path) \(out.width)x\(out.height); scroll directions: 4/4; video geometry: 2/2")
    }
}
