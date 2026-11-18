import AppKit

/// 按下时不位移、不改变图像，只用背景色反馈，避免按钮"跳动"
final class ToolButton: NSButton {
    var isActive = false {
        didSet { updateBackground() }
    }

    private var pressed = false

    override func highlight(_ flag: Bool) {
        pressed = flag
        updateBackground()
    }

    func updateBackground() {
        guard let layer else { return }
        if pressed {
            layer.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        } else if isActive {
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
        }
    }
}

final class ToolbarView: NSView {

    var onTool: ((Tool) -> Void)?
    var onUndo: (() -> Void)?
    var onColor: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: ((NSView) -> Void)?
    var onPin: (() -> Void)?
    var onRecordSelection: (() -> Void)?
    var onScrollCapture: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let buttonSize: CGFloat = 28
    private let padding: CGFloat = 6
    private let gap: CGFloat = 2

    private var toolButtons: [Tool: ToolButton] = [:]
    private var colorButton: ToolButton!
    private var undoButton: ToolButton!
    private var selectionMode = false
    private var canUndo = false
    private var items: [NSView] = []

    static let height: CGFloat = 40

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: ToolbarView.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.97).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        build()
        setActiveTool(.select)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 构建

    private func build() {
        for tool in Tool.visible {
            let b = makeButton(symbols: tool.symbols, tooltip: tool.title, action: #selector(toolTapped(_:)))
            b.tag = tool.rawValue
            if tool == .text { b.image = ToolbarView.letterIcon("A", size: 15) }
            if tool == .recognize { b.toolTip = "识别文字：拖选识别结果，⌘C 复制；再次点击退出" }
            toolButtons[tool] = b
            items.append(b)
        }

        items.append(separator())

        colorButton = makeButton(symbols: ["circle.fill"], tooltip: "选择标注颜色", action: #selector(colorTapped))
        colorButton.contentTintColor = Palette.colors[0]
        items.append(colorButton)

        undoButton = makeButton(symbols: ["arrow.uturn.backward"], tooltip: "撤销上一步 (⌘Z)", action: #selector(undoTapped))
        undoButton.isEnabled = false
        items.append(undoButton)

        items.append(separator())

        items.append(makeButton(symbols: ["pin", "pin.fill"], tooltip: "置顶：把截图悬浮在最顶层", action: #selector(pinTapped)))
        items.append(makeButton(symbols: ["record.circle"], tooltip: "录制当前选区（无音频，保存为 MP4）", action: #selector(recordSelectionTapped)))
        items.append(makeButton(symbols: ["arrow.up.and.down"], tooltip: "纵向截长图：自动识别上滚或下滚", action: #selector(verticalScrollTapped)))
        items.append(makeButton(symbols: ["arrow.left.and.right"], tooltip: "横向截长图：自动识别左移或右移", action: #selector(horizontalScrollTapped)))
        items.append(makeButton(symbols: ["doc.on.doc"], tooltip: "复制到剪贴板 (↩)", action: #selector(copyTapped)))
        items.append(makeButton(symbols: ["square.and.arrow.down"], tooltip: "保存 (⌘S)", action: #selector(saveTapped)))
        items.append(makeButton(symbols: ["xmark"], tooltip: "取消 (Esc)", action: #selector(closeTapped)))

        for v in items { addSubview(v) }
        resizeToFit()
    }

    private func makeButton(symbols: [String], tooltip: String, action: Selector) -> ToolButton {
        let b = ToolButton(frame: .zero)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        b.image = ToolbarView.symbol(symbols, size: 14)
        b.contentTintColor = NSColor(white: 0.93, alpha: 1)
        b.target = self
        b.action = action
        b.toolTip = tooltip
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.focusRingType = .none
        return b
    }

    private func separator() -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        v.identifier = NSUserInterfaceItemIdentifier("separator")
        return v
    }

    /// 自绘字母图标，避免系统符号被本地化成文字（如 textformat 在中文下显示"格式"）
    static func letterIcon(_ letter: String, size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size + 1, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
            let str = NSAttributedString(string: letter, attributes: attrs)
            let b = str.size()
            str.draw(at: NSPoint(x: (rect.width - b.width) / 2, y: (rect.height - b.height) / 2))
            return true
        }
        img.isTemplate = true
        return img
    }

    static func symbol(_ names: [String], size: CGFloat) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                return img
            }
        }
        return NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)
    }

    // MARK: 布局

    private func resizeToFit() {
        var x = padding
        for v in items {
            let isSep = v.identifier?.rawValue == "separator"
            let w: CGFloat = isSep ? 1 : buttonSize
            let h: CGFloat = isSep ? 18 : buttonSize
            v.frame = NSRect(x: x, y: (ToolbarView.height - h) / 2, width: w, height: h)
            x += w + gap
        }
        let width = x - gap + padding
        setFrameSize(NSSize(width: width, height: ToolbarView.height))
    }

    // MARK: 状态

    func setActiveTool(_ tool: Tool) {
        for (t, b) in toolButtons { b.isActive = (t == tool) }
    }

    func setColor(_ color: NSColor) {
        colorButton.contentTintColor = color
    }

    /// 颜色按钮中心（相对工具栏坐标），用来给色板定位
    var colorButtonCenter: NSPoint {
        let r = colorButton.convert(colorButton.bounds, to: self)
        return NSPoint(x: r.midX, y: r.midY)
    }

    func setColorButtonActive(_ active: Bool) {
        colorButton.isActive = active
    }

    func setCanUndo(_ can: Bool) {
        canUndo = can
        updateUndoEnabled()
    }

    private func updateUndoEnabled() {
        let enabled = canUndo && !selectionMode
        undoButton.isEnabled = enabled
        undoButton.contentTintColor = enabled ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.93, alpha: 0.3)
    }

    func setSelection(_ selection: NSRect?) {
        undoButton.toolTip = selection == nil ? "撤销上一步 (⌘Z)" : "撤销上一步；重选、移动、缩放和标注均可撤销 (⌘Z)"
    }

    func setSelectionMode(_ enabled: Bool) {
        selectionMode = enabled
        colorButton.isEnabled = !enabled
        updateUndoEnabled()
        for tool in Tool.visible {
            toolButtons[tool]?.isEnabled = true
        }
        if let recognize = toolButtons[.recognize] { recognize.isActive = enabled }
    }

    // MARK: 事件

    @objc private func toolTapped(_ sender: NSButton) {
        guard let tool = Tool(rawValue: sender.tag) else { return }
        setActiveTool(tool)
        onTool?(tool)
    }

    @objc private func colorTapped() { onColor?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?(self) }
    @objc private func pinTapped() { onPin?() }
    @objc private func recordSelectionTapped() { onRecordSelection?() }
    @objc private func verticalScrollTapped() { onScrollCapture?(true) }
    @objc private func horizontalScrollTapped() { onScrollCapture?(false) }
    @objc private func closeTapped() { onClose?() }
}
