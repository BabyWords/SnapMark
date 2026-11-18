import AppKit
import ImageIO

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// 窗口成为 key 时系统会先把光标重置成箭头，这时候需要补一次
    var onBecomeKey: (() -> Void)?
    override func becomeKey() {
        super.becomeKey()
        onBecomeKey?()
    }
}

/// 不吃鼠标事件的图层视图
class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

/// 只画标注和选区装饰的透明层，重绘成本低
final class CanvasView: PassthroughView {

    var baseImage: CGImage?
    var imageScale: CGFloat = 1

    var selection: NSRect? {
        didSet { needsDisplay = true }
    }
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var draft: Annotation? { didSet { needsDisplay = true } }
    var textSelectionMode = false { didSet { needsDisplay = true } }
    var recognizedLines: [OCRLine] = [] { didSet { needsDisplay = true } }
    var selectedText = "" { didSet { needsDisplay = true } }
    var textSelectionRect: NSRect? { didSet { needsDisplay = true } }
    var textSelectionRects: [NSRect] = [] { didSet { needsDisplay = true } }
    var recognizing = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        guard let sel = selection, sel.width > 0, sel.height > 0 else {
            drawHint()
            return
        }

        ctx.saveGState()
        ctx.clip(to: sel)
        var list = annotations
        if let d = draft { list.append(d) }
        Renderer.draw(list, in: ctx, imageScale: imageScale, base: baseImage)
        ctx.restoreGState()

        // 选框
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))

        let w = Int((sel.width * imageScale).rounded())
        let h = Int((sel.height * imageScale).rounded())
        var badgeY = sel.maxY + 6
        if badgeY + 20 > bounds.maxY { badgeY = sel.maxY - 24 }
        var badgeX = sel.minX
        if badgeX + 100 > bounds.maxX { badgeX = bounds.maxX - 106 }
        drawPill("\(w) × \(h)", at: NSPoint(x: badgeX, y: badgeY))
        drawResizeHandles(sel, in: ctx)
        if textSelectionMode {
            drawTextSelection(in: ctx)
            drawPill(recognizing ? "正在识别文字…" : "拖选文字 · ⌘C 复制 · 点击其他工具返回", at: NSPoint(x: sel.minX, y: badgeY - 22))
        }
    }

    private func drawTextSelection(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        for line in recognizedLines {
            let r = line.rect.insetBy(dx: -1, dy: -1)
            ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.5).cgColor)
            ctx.stroke(r)
        }
        if !selectedText.isEmpty {
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
            if !textSelectionRects.isEmpty {
                for rect in textSelectionRects { ctx.fill(rect) }
            } else if let textSelectionRect {
                ctx.fill(textSelectionRect)
            }
        }
        ctx.restoreGState()
    }

    private func drawResizeHandles(_ sel: NSRect, in ctx: CGContext) {
        let size: CGFloat = 6
        let half = size / 2
        let points = [
            NSPoint(x: sel.minX, y: sel.minY), NSPoint(x: sel.midX, y: sel.minY), NSPoint(x: sel.maxX, y: sel.minY),
            NSPoint(x: sel.minX, y: sel.midY), NSPoint(x: sel.maxX, y: sel.midY),
            NSPoint(x: sel.minX, y: sel.maxY), NSPoint(x: sel.midX, y: sel.maxY), NSPoint(x: sel.maxX, y: sel.maxY)
        ]
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        for p in points {
            let r = NSRect(x: p.x - half, y: p.y - half, width: size, height: size)
            ctx.fill(r)
            ctx.stroke(r)
        }
    }

    private func drawPill(_ text: String, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let h: CGFloat = 18
        let pad: CGFloat = 7
        let rect = NSRect(x: point.x, y: point.y, width: size.width + pad * 2, height: h)

        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        str.draw(with: NSRect(x: rect.minX + pad, y: rect.minY + (h - size.height) / 2,
                              width: size.width, height: size.height + 1),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private func drawHint() {
        let text = "拖动鼠标选择截图区域　·　右键 / Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 16
        let rect = NSRect(x: bounds.midX - (size.width + pad * 2) / 2,
                          y: bounds.midY - 16,
                          width: size.width + pad * 2,
                          height: 32)
        NSColor(white: 0, alpha: 0.62).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        str.draw(with: NSRect(x: rect.minX + pad, y: rect.minY + (34 - size.height) / 2,
                              width: size.width, height: size.height + 1),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

/// 截图主视图：负责交互
final class OverlayView: NSView, NSTextFieldDelegate {

    private let baseImage: CGImage
    private let imageScale: CGFloat

    private let dimView = PassthroughView()
    private let contentView = PassthroughView()
    private let canvas = CanvasView()
    private let maskLayer = CAShapeLayer()

    private(set) var selection: NSRect? {
        didSet {
            canvas.selection = selection
            updateMask()
            // 非拖拽过程中才重算光标区域，避免拖动时每帧都刷新
            if phase == .idle { refreshCursor() }
        }
    }
    private var annotations: [Annotation] = [] {
        didSet { canvas.annotations = annotations }
    }
    private var draft: Annotation? {
        didSet { canvas.draft = draft }
    }
    private var textSelectionMode = false {
        didSet {
            canvas.textSelectionMode = textSelectionMode
            toolbar?.setSelectionMode(textSelectionMode)
            window?.invalidateCursorRects(for: self)
            refreshCursor()
        }
    }
    private var recognizedLines: [OCRLine] = [] { didSet { canvas.recognizedLines = recognizedLines } }
    private var selectedText = "" { didSet { canvas.selectedText = selectedText } }
    private var textSelectionRect: NSRect? { didSet { canvas.textSelectionRect = textSelectionRect } }
    private var textSelectionRects: [NSRect] = [] { didSet { canvas.textSelectionRects = textSelectionRects } }
    private var recognizing = false { didSet { canvas.recognizing = recognizing } }
    private var textDragOrigin: NSPoint?
    private var selectedLineIndices: Set<Int> = []

    private enum Phase { case idle, selecting, annotating, moving, resizing, textSelecting }
    private enum ResizeHandle { case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight }
    private struct Snapshot {
        var selection: NSRect?
        var annotations: [Annotation]
    }
    private var history: [Snapshot] = []
    private let historyLimit = 30
    private var phase: Phase = .idle
    private var resizeHandle: ResizeHandle?
    private var resizeBaseSelection: NSRect = .zero
    private var resizeBaseAnnotations: [Annotation] = []
    private var moveHistoryBase: Snapshot?

    private var dragOrigin: NSPoint?
    private var savedSelection: NSRect?
    private var savedAnnotations: [Annotation] = []
    private var moveOrigin: NSPoint?
    private var moveBaseSelection: NSRect = .zero
    private var moveBaseAnnotations: [Annotation] = []

    /// 记住上次用过的工具（同一次运行内），首次默认"移动"
    private static var lastTool: Tool = .select
    private var tool: Tool = OverlayView.lastTool {
        didSet { OverlayView.lastTool = tool }
    }
    private var currentColor: NSColor = Palette.colors[0]
    private var palettePicker: PalettePickerView?

    private var toolbar: ToolbarView?
    private var textField: NSTextField?
    private var textAnchor: NSPoint = .zero
    private var committingText = false
    private var textEditBase: Snapshot?

    var onFinish: (() -> Void)?
    var onPinImage: ((CGImage, NSSize) -> Void)?

    init(frame: NSRect, baseImage: CGImage, imageScale: CGFloat) {
        self.baseImage = baseImage
        self.imageScale = imageScale
        super.init(frame: frame)
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    private func buildLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // 压暗层：整屏一次，之后不参与重绘
        dimView.frame = bounds
        dimView.autoresizingMask = [.width, .height]
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor(white: 0, alpha: 0.34).cgColor
        addSubview(dimView)

        // 底图：用 mask 裁出选区，拖动时只改 path，不重绘图像
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.contents = baseImage
        contentView.layer?.contentsGravity = .resize
        maskLayer.fillColor = NSColor.black.cgColor
        maskLayer.fillRule = .nonZero
        maskLayer.frame = bounds
        contentView.layer?.mask = maskLayer
        addSubview(contentView)

        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.baseImage = baseImage
        canvas.imageScale = imageScale
        addSubview(canvas)
    }

    private func updateMask() {
        if let sel = selection, sel.width > 0, sel.height > 0 {
            maskLayer.path = CGPath(rect: sel, transform: nil)
        } else {
            maskLayer.path = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        w.acceptsMouseMovedEvents = true
        w.makeFirstResponder(self)

        // 覆盖层出现时鼠标通常还没动过，屏幕上留着的仍是上一个 App 的光标。
        // 这里显式设成十字（尚未框选，唯一的合理状态），之后交给区域声明维持。
        // 注意：此时窗口还没 orderFront，系统在激活/成为 key 时会再把光标改回箭头，
        // 所以真正的"开场光标"由 primeCursor() 在窗口就位后再补一次。
        setInitialCursor()
        w.invalidateCursorRects(for: self)
    }

    /// 尚未框选时的光标只有十字一种可能。强制设置并同步缓存，
    /// 避免 appliedCursor 缓存让 refreshCursor 误判"已经是十字了"而跳过。
    func primeCursor() {
        guard selection == nil, phase == .idle else { return }
        setInitialCursor()
        window?.invalidateCursorRects(for: self)
    }

    private func setInitialCursor() {
        NSCursor.crosshair.set()
        appliedCursor = .crosshair
    }

    // MARK: 光标
    //
    // 光标的正确做法是"按区域声明"（cursor rect），由窗口服务器根据鼠标所在的
    // 矩形自动选光标：不依赖事件送达，也不受工具当前状态滞后影响。
    // 之前是整屏一块矩形、光标取"当前工具"——默认工具是移动，于是每次开局都是
    // 手形；换成标注工具后又变成十字；invalidate 还要等下一个事件周期才生效，
    // 于是表现为"有时手、有时十字"。

    private var cursorTracking: NSTrackingArea?
    private var appliedCursor: NSCursor?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = cursorTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.activeAlways, .inVisibleRect,
                                         .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        cursorTracking = t
    }

    /// 某点应有的光标（显式设置用，与 cursor rect 的规则保持一致）
    func cursor(at p: NSPoint) -> NSCursor {
        if let pv = palettePicker, pv.frame.contains(p) { return .arrow }
        if let tb = toolbar, !tb.isHidden, tb.frame.contains(p) { return .arrow }
        if phase == .moving { return .closedHand }
        if textSelectionMode, selection?.contains(p) == true { return .iBeam }
        if let sel = selection, resizeHandle(at: p, in: sel) != nil, phase == .idle {
            return .crosshair
        }
        if textSelectionMode, selection?.contains(p) == true { return .iBeam }
        if let sel = selection, sel.contains(p) { return insideCursor }
        return .crosshair
    }

    private var insideCursor: NSCursor {
        switch tool {
        case .select: return .openHand      // 可拖动整个选区
        case .text, .recognize: return .iBeam
        default:      return .crosshair     // 画标注
        }
    }

    private func orderedLineIndices() -> [Int] {
        recognizedLines.indices.sorted {
            let a = recognizedLines[$0].rect, b = recognizedLines[$1].rect
            if abs(a.midY - b.midY) < 4 { return a.minX < b.minX }
            return a.midY > b.midY
        }
    }

    private struct TextPosition {
        let lineIndex: Int
        let characterIndex: Int
        let distance: CGFloat
    }

    private func nearestTextPosition(to point: NSPoint) -> TextPosition? {
        var best: TextPosition?
        for lineIndex in orderedLineIndices() {
            let line = recognizedLines[lineIndex]
            for (characterIndex, character) in line.characters.enumerated() {
                let rect = character.rect
                let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
                let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
                let distance = hypot(dx, dy)
                if best == nil || distance < best!.distance {
                    best = TextPosition(lineIndex: lineIndex, characterIndex: characterIndex, distance: distance)
                }
            }
        }
        return best
    }

    private func selectedText(from start: TextPosition, to end: TextPosition) -> (String, [NSRect]) {
        let order = orderedLineIndices()
        guard let startOrder = order.firstIndex(of: start.lineIndex),
              let endOrder = order.firstIndex(of: end.lineIndex) else { return ("", []) }
        let forward = startOrder < endOrder || (startOrder == endOrder && start.characterIndex <= end.characterIndex)
        let first = forward ? start : end
        let last = forward ? end : start
        let firstOrder = forward ? startOrder : endOrder
        let lastOrder = forward ? endOrder : startOrder
        var parts: [String] = []
        var rects: [NSRect] = []

        for orderIndex in firstOrder...lastOrder {
            let lineIndex = order[orderIndex]
            let line = recognizedLines[lineIndex]
            guard !line.characters.isEmpty else { continue }
            let lower = orderIndex == firstOrder ? first.characterIndex : 0
            let upper = orderIndex == lastOrder ? last.characterIndex : line.characters.count - 1
            guard lower <= upper, lower >= 0, upper < line.characters.count else { continue }
            let chars = Array(line.characters[lower...upper])
            parts.append(chars.map(\.text).joined())
            let lineRects = chars.map(\.rect)
            if let union = lineRects.dropFirst().reduce(lineRects.first, { $0?.union($1) }) { rects.append(union) }
        }
        if !forward { parts.reverse(); rects.reverse() }
        return (parts.joined(separator: "\n"), rects)
    }

    private func textBetween(_ a: NSPoint, _ b: NSPoint) -> String {
        guard let start = nearestTextPosition(to: a), let end = nearestTextPosition(to: b) else {
            textSelectionRects = []
            textSelectionRect = nil
            return ""
        }
        let selected = selectedText(from: start, to: end)
        textSelectionRects = selected.1
        textSelectionRect = selected.1.dropFirst().reduce(selected.1.first) { $0?.union($1) }
        return selected.0
    }

    private var mousePoint: NSPoint? {
        guard let w = window else { return nil }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? p : nil
    }

    /// 状态变化后立刻重算区域，并在鼠标当前位置立即生效
    private func refreshCursor() {
        window?.invalidateCursorRects(for: self)
        guard let p = mousePoint else { return }
        setCursor(cursor(at: p))
    }

    /// 注意：这里必须"每次事件都真正 set"。
    /// 系统会在 App 激活 / 窗口成为 key / 指针进入窗口时把光标重置成箭头，
    /// 那是我们不感知的，缓存里记的"已经是十字"会让我们误判成"不用改"，
    /// 于是指针动了、光标却一直是箭头。set 本身很便宜，重复调用没有副作用。
    private func applyCursor(at p: NSPoint) {
        setCursor(cursor(at: p))
    }

    private func setCursor(_ want: NSCursor) {
        appliedCursor = want
        want.set()
    }

    override func resetCursorRects() {
        guard let sel = selection, sel.width >= 1, sel.height >= 1 else {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }

        // 选区外：十字，随时可以重新框选
        for r in OverlayView.rectsOutside(sel, in: bounds) {
            addCursorRect(r, cursor: .crosshair)
        }

        // 选区内：文字识别模式用 I 形光标，正常模式边缘手柄可调整大小。
        addCursorRect(sel, cursor: textSelectionMode ? .iBeam : (phase == .moving ? .closedHand : insideCursor))
        for r in resizeHandleRects(sel) { addCursorRect(r, cursor: .crosshair) }

        // 浮层上保持箭头，不要在按钮上出现十字
        if let tb = toolbar, !tb.isHidden { addCursorRect(tb.frame, cursor: .arrow) }
        if let pv = palettePicker { addCursorRect(pv.frame, cursor: .arrow) }
    }

    private func resizeHandleRects(_ sel: NSRect) -> [NSRect] {
        let hit: CGFloat = 18
        let half = hit / 2
        let points: [(ResizeHandle, NSPoint)] = [
            (.bottomLeft, NSPoint(x: sel.minX, y: sel.minY)), (.bottom, NSPoint(x: sel.midX, y: sel.minY)),
            (.bottomRight, NSPoint(x: sel.maxX, y: sel.minY)), (.left, NSPoint(x: sel.minX, y: sel.midY)),
            (.right, NSPoint(x: sel.maxX, y: sel.midY)), (.topLeft, NSPoint(x: sel.minX, y: sel.maxY)),
            (.top, NSPoint(x: sel.midX, y: sel.maxY)), (.topRight, NSPoint(x: sel.maxX, y: sel.maxY))
        ]
        return points.map { _, p in NSRect(x: p.x - half, y: p.y - half, width: hit, height: hit) }
    }

    private func resizeHandle(at p: NSPoint, in sel: NSRect) -> ResizeHandle? {
        let hitRects = resizeHandleRects(sel)
        let handles: [ResizeHandle] = [.bottomLeft, .bottom, .bottomRight, .left, .right, .topLeft, .top, .topRight]
        for (handle, rect) in zip(handles, hitRects) where rect.contains(p) { return handle }
        return nil
    }

    private func resizedSelection(from base: NSRect, handle: ResizeHandle, to p: NSPoint) -> NSRect {
        let minSize: CGFloat = 4
        var left = base.minX, right = base.maxX, bottom = base.minY, top = base.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft: left = min(max(p.x, bounds.minX), right - minSize)
        case .topRight, .right, .bottomRight: right = max(min(p.x, bounds.maxX), left + minSize)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .top, .topRight: top = max(min(p.y, bounds.maxY), bottom + minSize)
        case .bottomLeft, .bottom, .bottomRight: bottom = min(max(p.y, bounds.minY), top - minSize)
        case .left, .right: break
        }
        return NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    /// 选区把画面切成上 / 下 / 左 / 右四块
    static func rectsOutside(_ sel: NSRect, in bounds: NSRect) -> [NSRect] {
        let s = sel.intersection(bounds)
        guard !s.isNull, s.width > 0, s.height > 0 else { return [bounds] }
        var out: [NSRect] = []
        if s.minY > bounds.minY {
            out.append(NSRect(x: bounds.minX, y: bounds.minY,
                              width: bounds.width, height: s.minY - bounds.minY))
        }
        if s.maxY < bounds.maxY {
            out.append(NSRect(x: bounds.minX, y: s.maxY,
                              width: bounds.width, height: bounds.maxY - s.maxY))
        }
        if s.minX > bounds.minX {
            out.append(NSRect(x: bounds.minX, y: s.minY,
                              width: s.minX - bounds.minX, height: s.height))
        }
        if s.maxX < bounds.maxX {
            out.append(NSRect(x: s.maxX, y: s.minY,
                              width: bounds.maxX - s.maxX, height: s.height))
        }
        return out
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// 右键 = 取消这次截图。
    /// 唯一例外是正在输入文字：这时右键只结束输入，不把整张截图丢掉（和 Esc 一致）。
    override func rightMouseDown(with event: NSEvent) {
        if textField != nil { cancelText(); return }
        finish()
    }

    override func rightMouseUp(with event: NSEvent) {}

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        // 提交正在编辑的文字后继续处理这次点击，避免用户必须再点一次才能继续操作。
        if textField != nil { commitText() }

        // 点在别处就收起色板（点在色板内部时事件不会走到这里）
        if palettePicker != nil { hidePalette() }

        let p = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2, let sel = selection, sel.contains(p) {
            copyAndFinish()
            return
        }

        if textSelectionMode {
            guard !recognizing, selection?.contains(p) == true else { return }
            textDragOrigin = p
            selectedText = textBetween(p, p)
            phase = .textSelecting
            return
        }

        if let sel = selection, let handle = resizeHandle(at: p, in: sel), phase == .idle {
            resizeHandle = handle
            resizeBaseSelection = sel
            resizeBaseAnnotations = annotations
            phase = .resizing
            return
        }

        if let sel = selection, sel.contains(p) {
            // 移动整个选区（移动工具，或按住 ⌘ 临时移动）
            if tool == .select || event.modifierFlags.contains(.command) {
                phase = .moving
                moveOrigin = p
                moveHistoryBase = Snapshot(selection: selection, annotations: annotations)
                moveBaseSelection = sel
                moveBaseAnnotations = annotations
                refreshCursor()
                return
            }
            var a = Annotation(kind: tool.annotationKind, start: p, color: currentColor)
            if tool == .pen { a.points = [p] }
            draft = a
            phase = .annotating
            return
        }

        savedSelection = selection
        savedAnnotations = annotations
        selection = nil
        dragOrigin = p
        phase = .selecting
        toolbar?.isHidden = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        switch phase {
        case .selecting:
            guard let origin = dragOrigin else { return }
            var cur = p
            if event.modifierFlags.contains(.shift) {
                let dx = cur.x - origin.x, dy = cur.y - origin.y
                let s = max(abs(dx), abs(dy))
                cur = NSPoint(x: origin.x + (dx < 0 ? -s : s), y: origin.y + (dy < 0 ? -s : s))
            }
            selection = Annotation.rectBetween(clamp(origin), clamp(cur))

        case .annotating:
            guard var a = draft else { return }
            var cur = p
            if let sel = selection {
                cur = NSPoint(x: min(max(cur.x, sel.minX), sel.maxX),
                              y: min(max(cur.y, sel.minY), sel.maxY))
            }
            if a.kind == .pen {
                a.points.append(cur)
                a.end = cur
            } else {
                a.end = cur
            }
            draft = a

        case .moving:
            guard let mo = moveOrigin else { return }
            let dx = p.x - mo.x, dy = p.y - mo.y
            let base = moveBaseSelection
            let cdx = min(max(dx, bounds.minX - base.minX), bounds.maxX - base.maxX)
            let cdy = min(max(dy, bounds.minY - base.minY), bounds.maxY - base.maxY)
            selection = base.offsetBy(dx: cdx, dy: cdy)
            annotations = moveBaseAnnotations.map { $0.offsetBy(dx: cdx, dy: cdy) }
            layoutToolbar()

        case .resizing:
            guard let handle = resizeHandle else { return }
            selection = resizedSelection(from: resizeBaseSelection, handle: handle, to: p)
            layoutToolbar()

        case .textSelecting:
            guard let origin = textDragOrigin else { return }
            selectedText = textBetween(origin, p)

        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch phase {
        case .selecting:
            dragOrigin = nil
            phase = .idle
            if let r = selection, r.width >= 4, r.height >= 4 {
                if let old = savedSelection, abs(old.width - r.width) < 1.5, abs(old.height - r.height) < 1.5,
                   abs(old.minX - r.minX) < 1.5, abs(old.minY - r.minY) < 1.5 {
                    annotations = savedAnnotations
                } else {
                    pushHistory(selection: savedSelection, annotations: savedAnnotations)
                    annotations = []
                }
                showToolbar()
            } else {
                selection = savedSelection
                annotations = savedAnnotations
                // 轻点/过小拖动会回退到原选区，工具栏也必须一起恢复。
                if selection != nil { showToolbar() }
            }
            savedSelection = nil
            savedAnnotations = []
            refreshUndo()
            refreshCursor()

        case .annotating:
            phase = .idle
            guard let a = draft else { return }
            draft = nil
            if a.kind == .text {
                textAnchor = a.start
                beginTextEditing(at: a.start)
            } else if a.kind == .pen && a.points.count < 2 {
                // 轻点忽略
            } else if a.kind != .pen && hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 3 {
                // 太小忽略
            } else {
                pushHistory(selection: selection, annotations: annotations)
                annotations.append(a)
                refreshUndo()
            }

        case .moving:
            phase = .idle
            moveOrigin = nil
            if selection != moveBaseSelection {
                pushHistory(selection: moveHistoryBase?.selection ?? moveBaseSelection,
                            annotations: moveHistoryBase?.annotations ?? moveBaseAnnotations)
            }
            moveHistoryBase = nil
            refreshUndo()
            refreshCursor()

        case .resizing:
            phase = .idle
            resizeHandle = nil
            if selection != resizeBaseSelection {
                pushHistory(selection: resizeBaseSelection, annotations: resizeBaseAnnotations)
            }
            refreshUndo()
            refreshCursor()

        case .textSelecting:
            phase = .idle
            textDragOrigin = nil

        case .idle:
            break
        }
        refreshCursor()
    }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX),
                y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    // MARK: 工具栏

    private func showToolbar() {
        if toolbar == nil {
            let tb = ToolbarView()
            tb.onTool = { [weak self] t in
                guard let self else { return }
                self.commitText()
                if t == .recognize, self.textSelectionMode {
                    self.textSelectionMode = false
                    self.tool = .select
                    self.toolbar?.setActiveTool(.select)
                } else {
                    self.tool = t
                    self.toolbar?.setActiveTool(t)
                    if t == .recognize { self.beginTextSelectionMode() }
                    else { self.textSelectionMode = false }
                }
                self.refreshCursor()
            }
            tb.onUndo = { [weak self] in
                guard let self else { return }
                self.commitText()
                self.undo()
            }
            tb.onColor = { [weak self] in self?.togglePalette() }
            tb.onCopy = { [weak self] in
                guard let self else { return }
                self.commitText()
                self.copyAndFinish()
            }
            tb.onSave = { [weak self] _ in
                guard let self else { return }
                self.commitText()
                self.saveImage()
            }
            tb.onPin = { [weak self] in
                guard let self else { return }
                self.commitText()
                self.pinAndFinish()
            }
            tb.onClose = { [weak self] in self?.finish() }
            addSubview(tb)
            toolbar = tb
            tb.setActiveTool(tool)
            tb.setColor(currentColor)
        }
        toolbar?.isHidden = false
        layoutToolbar()
        refreshCursor()
    }

    private func layoutToolbar() {
        guard let sel = selection, let tb = toolbar else { return }
        let size = tb.frame.size
        let margin: CGFloat = 10
        var y = sel.minY - size.height - margin
        if y < margin { y = sel.maxY + margin }
        if y + size.height > bounds.maxY - margin {
            y = max(margin, min(sel.maxY - size.height - margin, bounds.maxY - size.height - margin))
        }
        var x = sel.midX - size.width / 2
        x = min(max(margin, x), bounds.maxX - size.width - margin)
        tb.frame.origin = NSPoint(x: x, y: y)
        layoutPalette()
    }

    private func pushHistory(selection: NSRect?, annotations: [Annotation]) {
        history.append(Snapshot(selection: selection, annotations: annotations))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        refreshUndo()
    }

    private func refreshUndo() {
        toolbar?.setCanUndo(!history.isEmpty)
        toolbar?.setSelection(selection)
    }

    private func setColor(_ color: NSColor) {
        currentColor = color
        toolbar?.setColor(color)
        palettePicker?.current = color
        if let tf = textField { tf.textColor = color }
    }

    // MARK: 色板

    private func togglePalette() {
        if palettePicker == nil {
            let pv = PalettePickerView(frame: NSRect(origin: .zero, size: PalettePickerView.panelSize))
            pv.current = currentColor
            pv.onPick = { [weak self] color in self?.setColor(color) }
            addSubview(pv)
            palettePicker = pv
            toolbar?.setColorButtonActive(true)
            refreshCursor()
            layoutPalette()
        } else {
            hidePalette()
        }
    }

    private func hidePalette() {
        palettePicker?.removeFromSuperview()
        palettePicker = nil
        toolbar?.setColorButtonActive(false)
        refreshCursor()
    }

    private func layoutPalette() {
        guard let pv = palettePicker, let tb = toolbar else { return }
        let size = pv.frame.size
        let margin: CGFloat = 10
        // 优先对齐颜色按钮
        let anchorX = tb.frame.minX + tb.colorButtonCenter.x
        var x = anchorX - size.width / 2
        x = min(max(margin, x), bounds.maxX - size.width - margin)
        var y = tb.frame.minY - size.height - 8
        // 工具栏在选区上方时，色板也跟着放到工具栏上面，别压住截图内容
        if let sel = selection, tb.frame.midY > sel.midY { y = tb.frame.maxY + 8 }
        if y + size.height > bounds.maxY - margin { y = tb.frame.minY - size.height - 8 }
        if y < margin { y = tb.frame.maxY + 8 }
        pv.frame.origin = NSPoint(x: x, y: y)
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        selection = previous.selection
        annotations = previous.annotations
        if selection != nil { showToolbar() } else { toolbar?.isHidden = true }
        refreshUndo()
        refreshCursor()
    }

    private func beginTextSelectionMode() {
        guard let sel = selection, !recognizing else { return }
        textSelectionMode = true
        selectedText = ""
        recognizedLines = []
        recognizing = true
        let crop = NSRect(x: sel.minX * imageScale, y: sel.minY * imageScale,
                          width: sel.width * imageScale, height: sel.height * imageScale).integral
        guard let image = baseImage.cropping(to: CGRect(x: crop.minX,
                                                        y: CGFloat(baseImage.height) - crop.maxY,
                                                        width: crop.width, height: crop.height)) else {
            recognizing = false
            showOutputError("无法准备截图区域。")
            return
        }
        TextRecognizer.recognize(image) { [weak self] result in
            guard let self else { return }
            self.recognizing = false
            switch result {
            case .success(let lines):
                self.recognizedLines = lines.map { line in
                    let r = line.rect
                    let chars = line.characters.map { character in
                        let box = character.rect
                        return OCRCharacter(text: character.text,
                                            rect: NSRect(x: sel.minX + box.minX * sel.width,
                                                         y: sel.minY + box.minY * sel.height,
                                                         width: box.width * sel.width,
                                                         height: box.height * sel.height))
                    }
                    return OCRLine(text: line.text,
                                   rect: NSRect(x: sel.minX + r.minX * sel.width,
                                                y: sel.minY + r.minY * sel.height,
                                                width: r.width * sel.width,
                                                height: r.height * sel.height),
                                   confidence: line.confidence,
                                   characters: chars)
                }
                if lines.isEmpty { self.showOutputError("没有识别到文字。") }
            case .failure:
                self.showOutputError("文字识别失败，请换一张更清晰的截图重试。")
            }
        }
    }

    // MARK: 文字输入

    private func beginTextEditing(at p: NSPoint) {
        let height: CGFloat = 30
        let tf = NSTextField(frame: NSRect(x: p.x, y: p.y - height, width: 240, height: height))
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        tf.textColor = currentColor
        tf.delegate = self
        tf.target = self
        tf.action = #selector(textCommitted)
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        addSubview(tf)
        textField = tf
        textEditBase = Snapshot(selection: selection, annotations: annotations)
        window?.makeFirstResponder(tf)
    }

    @objc private func textCommitted() { commitText() }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    private func commitText() {
        guard let tf = textField, !committingText else { return }
        committingText = true
        let text = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        textField = nil
        tf.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !text.isEmpty {
            var a = Annotation(kind: .text, start: textAnchor, color: currentColor)
            a.text = text
            a.fontSize = 18
            if let base = textEditBase { pushHistory(selection: base.selection, annotations: base.annotations) }
            annotations.append(a)
        }
        textEditBase = nil
        committingText = false
        refreshUndo()
    }

    private func cancelText() {
        guard let tf = textField else { return }
        committingText = true
        textField = nil
        tf.removeFromSuperview()
        window?.makeFirstResponder(self)
        textEditBase = nil
        committingText = false
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        if textField != nil, event.keyCode == 53 { cancelText(); return }
        if textSelectionMode, event.keyCode == 53 {
            textSelectionMode = false
            tool = .select
            toolbar?.setActiveTool(.select)
            return
        }

        switch event.keyCode {
        case 53:                       // Esc
            if palettePicker != nil { hidePalette(); return }
            finish()
        case 36, 76:                   // Return / Enter
            copyAndFinish()
        case 51:                       // Delete
            undo()
        default:
            // 方向键微调选区（按住 Shift 每次 10 点）
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch event.keyCode {
            case 123: dx = -step
            case 124: dx = step
            case 125: dy = -step
            case 126: dy = step
            default: super.keyDown(with: event); return
            }
            guard let sel = selection else { return }
            let nx = min(max(sel.minX + dx, bounds.minX), bounds.maxX - sel.width)
            let ny = min(max(sel.minY + dy, bounds.minY), bounds.maxY - sel.height)
            let ddx = nx - sel.minX, ddy = ny - sel.minY
            guard ddx != 0 || ddy != 0 else { return }
            selection = sel.offsetBy(dx: ddx, dy: ddy)
            annotations = annotations.map { $0.offsetBy(dx: ddx, dy: ddy) }
            layoutToolbar()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard textField == nil, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, let ch = event.charactersIgnoringModifiers?.lowercased() {
            if textSelectionMode && ch == "c" {
                copyRecognizedText()
                return true
            }
            switch ch {
            case "c": copyAndFinish(); return true
            case "z": undo(); return true
            case "s": saveImage(); return true
            case "w": finish(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: 输出

    private func copyRecognizedText() {
        guard !selectedText.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(selectedText, forType: .string) else {
            showOutputError("无法复制识别文字。")
            return
        }
        NSSound(named: NSSound.Name("Tink"))?.play()
    }

    private func compositeImage() -> CGImage? {
        guard let sel = selection else { return nil }
        return Compositor.render(base: baseImage, selection: sel, imageScale: imageScale, annotations: annotations)
    }

    private func pinAndFinish() {
        guard let img = compositeImage(), let sel = selection else {
            showOutputError("没有可置顶的截图内容。")
            return
        }
        onPinImage?(img, sel.size)
        finish()
    }

    private var dpi: CGFloat { 72 * imageScale }

    private var exportProperties: [CFString: Any] {
        [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    }

    private func copyAndFinish() {
        guard let img = compositeImage() else {
            showOutputError("没有可复制的截图内容。")
            return
        }

        // 不能直接写 NSImage：AppKit 会按点尺寸以 72DPI 重新栅格化，Retina 数据会被降采样变糊。
        // 先编码、确认至少有一种数据成功，再清空剪贴板，避免失败时破坏用户原内容。
        let png = OverlayView.encode(img, type: "public.png" as CFString, properties: exportProperties)
        let tiff = OverlayView.encode(img, type: "public.tiff" as CFString, properties: exportProperties)
        guard png != nil || tiff != nil else {
            showOutputError("图片编码失败，原剪贴板内容未被修改。")
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        var wrote = false
        if let png { wrote = pb.setData(png, forType: .png) || wrote }
        if let tiff { wrote = pb.setData(tiff, forType: .tiff) || wrote }
        guard wrote else {
            showOutputError("无法写入剪贴板，原剪贴板内容可能仍在。")
            return
        }

        NSSound(named: NSSound.Name("Tink"))?.play()
        finish()
    }

    private func saveImage() {
        guard let img = compositeImage() else {
            showOutputError("没有可保存的截图内容。")
            return
        }
        let dir = SaveLocationStore.directory

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stem = "SnapMark-\(fmt.string(from: Date()))"
        var url = dir.appendingPathComponent("\(stem).png")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem)-\(index).png")
            index += 1
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            showOutputError("无法创建截图文件，截图未保存。")
            return
        }
        CGImageDestinationAddImage(dest, img, exportProperties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            showOutputError("写入截图文件失败，截图未保存。")
            return
        }
        NSSound(named: NSSound.Name("Glass"))?.play()
        finish()
    }

    private func showOutputError(_ message: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "SnapMark"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func encode(_ image: CGImage, type: CFString, properties: [CFString: Any]?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func finish() {
        toolbar?.isHidden = true
        // 收起时把光标还原，否则松开手型/十字会"粘"到别的 App 上
        NSCursor.arrow.set()
        onFinish?()
    }
}

extension OverlayView {
    /// 仅开发自检用
    func applyPreset(selection: NSRect, annotations: [Annotation]) {
        self.selection = selection
        self.annotations = annotations
        showToolbar()
        refreshUndo()
    }

    /// 仅开发自检用：打开色板，方便截图核对排版
    func togglePaletteForTest() {
        togglePalette()
    }
}

// MARK: - 控制器

final class OverlayController {

    private let screen: NSScreen
    private let image: CGImage
    private let previousApplication: NSRunningApplication?
    private var window: OverlayWindow?
    private var view: OverlayView?
    var onClose: (() -> Void)?
    var onPinImage: ((CGImage, NSSize) -> Void)?

    init(screen: NSScreen, image: CGImage) {
        self.screen = screen
        self.image = image
        let current = NSRunningApplication.current.bundleIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        self.previousApplication = front?.bundleIdentifier == current ? nil : front
    }

    /// 抓到的像素宽 / 屏幕点宽，取整避免 1.9995 这类比例造成缩放发虚
    var imageScale: CGFloat {
        let raw = CGFloat(image.width) / max(1, screen.frame.width)
        let rounded = raw.rounded()
        return abs(raw - rounded) < 0.02 ? rounded : raw
    }

    func begin() {
        let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.setFrame(screen.frame, display: true)

        let v = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                            baseImage: image, imageScale: imageScale)
        v.onFinish = { [weak self] in self?.close() }
        v.onPinImage = { [weak self] image, size in self?.onPinImage?(image, size) }
        w.contentView = v

        window = w
        view = v

        // 退到后台 App 时系统的"协作式激活"只让我们逻辑上 active，
        // 窗口服务器仍把光标算在上一个 App 名下，NSCursor.set 就不显示。
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)

        // 开场光标：系统在 App 激活 / 窗口成为 key 时会把光标重置成箭头，
        // 所以要在窗口就位之后、以及 becomeKey 时各补一次十字。
        // 激活是异步的（可能比 makeKey 还晚），再用几个短延时补几枪，兜住时序。
        w.onBecomeKey = { [weak v] in v?.primeCursor() }
        v.primeCursor()
        DispatchQueue.main.async { [weak v] in v?.primeCursor() }
        for d in [0.15, 0.35, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak v] in v?.primeCursor() }
        }
    }

    /// 仅开发自检用
    func preset(selection: NSRect, annotations: [Annotation]) {
        view?.applyPreset(selection: selection, annotations: annotations)
    }

    /// 仅开发自检用：自动打开色板
    func openPaletteForTest() {
        view?.togglePaletteForTest()
    }

    func close() {
        guard let w = window else { return }
        window = nil
        view = nil
        // 覆盖层消失后光标交还给系统默认箭头，避免残留在其他应用上
        NSCursor.arrow.set()
        onClose?()
        onClose = nil
        w.orderOut(nil)
        // 把输入焦点交还给截图前的应用，复制后可以直接粘贴。
        if let previousApplication {
            DispatchQueue.main.async {
                previousApplication.activate(options: [.activateAllWindows])
            }
        }
        // 可能正在处理该窗口的鼠标/键盘事件，延后一个 runloop 再释放
        DispatchQueue.main.async { _ = w }
    }
}
