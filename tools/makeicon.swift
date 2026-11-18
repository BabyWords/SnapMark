import AppKit
import CoreGraphics
import ImageIO
import Foundation

// SnapMark 图标生成器
// 用法: swiftc -O makeicon.swift -o makeicon && ./makeicon <输出目录>
// 生成 1024 主图 + 各变体预览

let S: CGFloat = 1024
let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)

// MARK: - 工具

func squircle(_ rect: CGRect, n: CGFloat = 5.0, steps: Int = 1600) -> CGPath {
    let p = CGMutablePath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func context(_ size: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / S, y: CGFloat(size) / S)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

/// 取景角：横竖两条线段都从角点出发，圆头画笔在角点自然重叠，
/// 形成干净的圆角，不依赖弧线方向计算（之前用 addArc 四个角里有一个画歪）。
func bracketPaths(corner c: CGPoint, sx: CGFloat, sy: CGFloat, arm: CGFloat) -> [CGPath] {
    let h = CGMutablePath()
    h.move(to: c)
    h.addLine(to: CGPoint(x: c.x + sx * arm, y: c.y))

    let v = CGMutablePath()
    v.move(to: c)
    v.addLine(to: CGPoint(x: c.x, y: c.y + sy * arm))
    return [h, v]
}

/// 箭头：单个闭合多边形（杆 + 三角头），一次填充，避免接缝
func arrowPath(from tail: CGPoint, to tip: CGPoint,
               width w: CGFloat, headLength hl: CGFloat, headHalf hh: CGFloat) -> CGPath {
    let dx = tip.x - tail.x, dy = tip.y - tail.y
    let len = max(sqrt(dx * dx + dy * dy), 0.001)
    let ux = dx / len, uy = dy / len
    let nx = -uy, ny = ux
    let hw = w / 2
    let neck = CGPoint(x: tip.x - ux * hl, y: tip.y - uy * hl)

    let p = CGMutablePath()
    p.move(to: CGPoint(x: tail.x + nx * hw, y: tail.y + ny * hw))
    p.addLine(to: CGPoint(x: neck.x + nx * hw, y: neck.y + ny * hw))
    p.addLine(to: CGPoint(x: neck.x + nx * hh, y: neck.y + ny * hh))
    p.addLine(to: tip)
    p.addLine(to: CGPoint(x: neck.x - nx * hh, y: neck.y - ny * hh))
    p.addLine(to: CGPoint(x: neck.x - nx * hw, y: neck.y - ny * hw))
    p.addLine(to: CGPoint(x: tail.x - nx * hw, y: tail.y - ny * hw))
    p.closeSubpath()
    return p
}

// MARK: - 图标

enum Variant: String, CaseIterable {
    case frame      // 取景框 + 勾（"已复制"）
    case arrow      // 取景框 + 箭头（"标注"）
    case plain      // 只有取景框
}

func drawIcon(_ ctx: CGContext, variant: Variant, boost: CGFloat = 1, simple: Bool = false) {
    let plate = squircle(plateRect)

    // 底板（不烘焙投影，Dock/Finder 会自己加）
    ctx.addPath(plate)
    ctx.setFillColor(rgb(0x241272))
    ctx.fillPath()

    // 底板渐变
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: cs,
                          colors: [rgb(0x6E8BFF), rgb(0x3C4AD1), rgb(0x241272)] as CFArray,
                          locations: [0.0, 0.52, 1.0])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: plateRect.minX + 20, y: plateRect.maxY - 10),
                           end: CGPoint(x: plateRect.maxX - 20, y: plateRect.minY + 20),
                           options: [])

    // 中心柔光，让中间的图形浮起来
    let glow = CGGradient(colorsSpace: cs,
                          colors: [rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0.0)] as CFArray,
                          locations: [0.0, 1.0])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 430, options: [])

    // 顶部高光
    let sheen = CGGradient(colorsSpace: cs,
                           colors: [rgb(0xFFFFFF, 0.26), rgb(0xFFFFFF, 0.0)] as CFArray,
                           locations: [0.0, 1.0])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: plateRect.maxY),
                           end: CGPoint(x: 0, y: plateRect.midY + 70), options: [])
    ctx.restoreGState()

    // 四角取景框
    let inset: CGFloat = 234
    let arm: CGFloat = 174
    let lw: CGFloat = 56 * boost

    if !simple {
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: inset, y: inset), 1, 1),
            (CGPoint(x: inset, y: S - inset), 1, -1),
            (CGPoint(x: S - inset, y: S - inset), -1, -1),
            (CGPoint(x: S - inset, y: inset), -1, 1)
        ]
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0xFFFFFF))
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (c, sx, sy) in corners {
            for p in bracketPaths(corner: c, sx: sx, sy: sy, arm: arm) {
                ctx.addPath(p)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    // 中心图形
    // 小尺寸时取景框省略，只留一个放大的勾/箭头，避免 16~32px 糊成一团
    let contentScale: CGFloat = simple ? 1.22 : 0.80
    let center = CGPoint(x: 512, y: 506)
    func scalePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (p.x - center.x) * contentScale,
                y: center.y + (p.y - center.y) * contentScale)
    }

    switch variant {
    case .plain:
        break

    case .frame:
        let check = CGMutablePath()
        check.move(to: scalePoint(CGPoint(x: 392, y: 492)))
        check.addLine(to: scalePoint(CGPoint(x: 480, y: 404)))
        check.addLine(to: scalePoint(CGPoint(x: 650, y: 600)))
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0xFF6A57))
        ctx.setLineWidth((simple ? 96 : 82) * boost)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(check)
        ctx.strokePath()
        ctx.restoreGState()

    case .arrow:
        // 左上指向右下
        let tail = scalePoint(CGPoint(x: 404, y: 624))
        let tip = scalePoint(CGPoint(x: 642, y: 386))
        ctx.saveGState()
        ctx.setFillColor(rgb(0xFF7A45))
        ctx.setLineJoin(.round)
        ctx.addPath(arrowPath(from: tail, to: tip,
                              width: 70 * boost, headLength: 128 * boost, headHalf: 96 * boost))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

func render(_ variant: Variant, size: Int, boost: CGFloat = 1, simple: Bool = false) -> CGImage {
    let ctx = context(size)
    drawIcon(ctx, variant: variant, boost: boost, simple: simple)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// 小尺寸下线条按比例会细到看不见，适当加粗，保证 16/32px 仍可辨识
func boostFor(_ px: Int) -> CGFloat {
    switch px {
    case ..<24: return 1.50
    case ..<40: return 1.28
    case ..<100: return 1.14
    default: return 1.0
    }
}

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "/tmp/snapmark-icon"
let variant: Variant = args.count > 3 ? (Variant(rawValue: args[3]) ?? .frame) : .frame
let icnsPath = args.count > 2 && args[2] != "-" ? args[2] : nil

// 预览
for v in Variant.allCases {
    writePNG(render(v, size: 1024), to: "\(outDir)/preview-\(v.rawValue).png")
    writePNG(render(v, size: 128), to: "\(outDir)/preview-\(v.rawValue)-128.png")
    writePNG(render(v, size: 32, boost: boostFor(32), simple: true), to: "\(outDir)/preview-\(v.rawValue)-32.png")
    print("preview: \(outDir)/preview-\(v.rawValue).png")
}

// iconset -> icns
if let icnsPath {
    let iconset = outDir + "/AppIcon.iconset"
    try? FileManager.default.removeItem(atPath: iconset)
    try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

    let entries: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]
    for (name, px) in entries {
        writePNG(render(variant, size: px, boost: boostFor(px), simple: px <= 32), to: "\(iconset)/\(name)")
    }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset, "-o", icnsPath]
    try? p.run()
    p.waitUntilExit()
    print(p.terminationStatus == 0 ? "icns: \(icnsPath)" : "iconutil 失败: \(p.terminationStatus)")
}
