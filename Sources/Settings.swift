import AppKit

/// 快捷键录制框
final class HotKeyField: NSView {

    var combo: HotKeyCombo = HotKeyStore.load() {
        didSet { needsDisplay = true }
    }
    var isRecording = false {
        didSet { needsDisplay = true }
    }
    var onChange: ((HotKeyCombo) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        NSColor(white: 0, alpha: 0.06).setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor(white: 0, alpha: 0.18)).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = isRecording ? "请按下组合键…" : combo.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 21, weight: .medium),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(with: NSRect(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2,
                              width: size.width + 2, height: size.height + 2),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { stopRecording(); return }
        commit(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 53 { stopRecording(); return true }
        commit(event)
        return true
    }

    private func commit(_ event: NSEvent) {
        guard let c = HotKeyCombo.from(event: event) else {
            NSSound.beep()
            return
        }
        combo = c
        isRecording = false
        window?.makeFirstResponder(nil)
        onChange?(c)
    }

    private func stopRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
    }
}

/// 设置窗口
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    /// 返回 false 表示注册失败（被系统或其他 App 占用）
    var applyHandler: ((HotKeyCombo) -> Bool)?

    private var window: NSWindow?
    private var field: HotKeyField?

    func show() {
        if window == nil { build() }
        field?.combo = HotKeyStore.load()
        field?.isRecording = false
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 252),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "SnapMark 设置"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 252))

        let title = NSTextField(labelWithString: "截图快捷键")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 24, y: 210, width: 300, height: 18)

        let sub = NSTextField(labelWithString: "点击方框后按下新的组合键，需包含 ⌘ / ⌥ / ⌃ 之一")
        sub.font = NSFont.systemFont(ofSize: 11.5)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 24, y: 188, width: 372, height: 16)

        let field = HotKeyField(frame: NSRect(x: 24, y: 112, width: 372, height: 56))
        field.onChange = { [weak self] combo in
            guard let self else { return }
            let ok = self.applyHandler?(combo) ?? false
            if !ok {
                NSSound.beep()
                self.field?.combo = HotKeyStore.load()
                let alert = NSAlert()
                alert.messageText = "这个快捷键用不了"
                alert.informativeText = "它可能已被系统或其他应用占用，换一个组合试试。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }

        let hint = NSTextField(labelWithString: "录制时按 Esc 取消，修改立即生效")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 24, y: 88, width: 372, height: 15)

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 24, y: 26, width: 96, height: 32)

        let done = NSButton(title: "完成", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 320, y: 26, width: 76, height: 32)

        for v in [title, sub, field, hint, reset, done] as [NSView] { content.addSubview(v) }
        w.contentView = content

        self.window = w
        self.field = field
    }

    @objc private func resetTapped() {
        field?.combo = .default
        let ok = applyHandler?(.default) ?? false
        if !ok {
            NSSound.beep()
            field?.combo = HotKeyStore.load()
        }
    }

    @objc private func doneTapped() {
        window?.orderOut(nil)
    }
}
