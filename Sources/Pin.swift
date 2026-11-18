import AppKit
import ImageIO

/// 置顶悬浮图片：截图钉住后浮在所有窗口之上，可拖动，右键保存或销毁。
final class PinnedImageController {

    private let window: NSWindow
    private let image: CGImage
    private let pinView: PinView

    var onClose: (() -> Void)?

    init(image: CGImage, pointSize: NSSize) {
        self.image = image
        let size = PinnedImageController.fittedSize(for: pointSize)

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false

        let view = PinView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        w.contentView = view

        self.window = w
        self.pinView = view

        view.onSave = { [weak self] in self?.saveToDesktop() }
        view.onDestroy = { [weak self] in self?.close() }
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private static func fittedSize(for raw: NSSize) -> NSSize {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return raw }
        let frame = screen.visibleFrame
        let maxW = frame.width * 0.85
        let maxH = frame.height * 0.85
        let scale = min(1, maxW / max(1, raw.width), maxH / max(1, raw.height))
        return NSSize(width: max(1, raw.width * scale), height: max(1, raw.height * scale))
    }

    private func saveToDesktop() {
        guard let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            showError("找不到桌面目录，图片未保存。")
            return
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stem = "SnapMark-Pin-\(fmt.string(from: Date()))"
        var url = dir.appendingPathComponent("\(stem).png")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem)-\(index).png")
            index += 1
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            showError("无法创建图片文件，图片未保存。")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            showError("写入图片文件失败，图片未保存。")
            return
        }
        NSSound(named: NSSound.Name("Glass"))?.play()
        close()
    }

    private func close() {
        window.orderOut(nil)
        onClose?()
        onClose = nil
    }

    private func showError(_ message: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "SnapMark"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// 显示图片并处理右键菜单
final class PinView: NSView {

    var image: NSImage?
    var onSave: (() -> Void)?
    var onDestroy: (() -> Void)?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSColor.clear.setFill()
        dirtyRect.fill()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let save = NSMenuItem(title: "保存到桌面", action: #selector(saveTapped), keyEquivalent: "")
        let destroy = NSMenuItem(title: "销毁", action: #selector(destroyTapped), keyEquivalent: "")
        save.target = self
        destroy.target = self
        menu.addItem(save)
        menu.addItem(destroy)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func saveTapped() { onSave?() }
    @objc private func destroyTapped() { onDestroy?() }
}
