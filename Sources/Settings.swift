import AppKit

/// 截图保存目录的持久化，默认「下载」文件夹。
enum SaveLocationStore {
    private static let key = "SnapMark.saveDirectory"

    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: key),
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func set(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: key)
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

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
    private var pathLabel: NSTextField?

    func show() {
        if window == nil { build() }
        field?.combo = HotKeyStore.load()
        field?.isRecording = false
        refreshPathLabel()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "SnapMark 设置"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))

        // 快捷键分组
        let title = NSTextField(labelWithString: "截图快捷键")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 24, y: 358, width: 300, height: 18)

        let sub = NSTextField(labelWithString: "点击方框后按下新的组合键，需包含 ⌘ / ⌥ / ⌃ 之一")
        sub.font = NSFont.systemFont(ofSize: 11.5)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 24, y: 336, width: 372, height: 16)

        let field = HotKeyField(frame: NSRect(x: 24, y: 262, width: 372, height: 56))
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
        hint.frame = NSRect(x: 24, y: 238, width: 372, height: 15)

        // 保存位置分组
        let saveTitle = NSTextField(labelWithString: "保存位置")
        saveTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        saveTitle.frame = NSRect(x: 24, y: 206, width: 300, height: 18)

        let pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = NSFont.systemFont(ofSize: 11.5)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: 24, y: 172, width: 372, height: 22)

        let select = NSButton(title: "选择文件夹…", target: self, action: #selector(selectFolderTapped))
        select.bezelStyle = .rounded
        select.frame = NSRect(x: 24, y: 128, width: 130, height: 32)

        let resetSave = NSButton(title: "使用下载文件夹", target: self, action: #selector(resetSaveTapped))
        resetSave.bezelStyle = .rounded
        resetSave.frame = NSRect(x: 166, y: 128, width: 150, height: 32)

        // 底部按钮
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 24, y: 26, width: 96, height: 32)

        let done = NSButton(title: "完成", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 320, y: 26, width: 76, height: 32)

        for v in [title, sub, field, hint, saveTitle, pathLabel, select, resetSave, reset, done] as [NSView] {
            content.addSubview(v)
        }
        w.contentView = content

        self.window = w
        self.field = field
        self.pathLabel = pathLabel
    }

    private func refreshPathLabel() {
        pathLabel?.stringValue = "当前保存到：\(SaveLocationStore.directory.path)"
        pathLabel?.toolTip = SaveLocationStore.directory.path
    }

    @objc private func selectFolderTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择截图保存位置"
        panel.directoryURL = SaveLocationStore.directory
        if panel.runModal() == .OK, let url = panel.url {
            SaveLocationStore.set(url)
            refreshPathLabel()
        }
    }

    @objc private func resetSaveTapped() {
        SaveLocationStore.resetToDefault()
        refreshPathLabel()
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
