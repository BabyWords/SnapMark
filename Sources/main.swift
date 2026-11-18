import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var captureItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var controller: OverlayController?
    private var pinnedWindows: [PinnedImageController] = []
    private var capturing = false
    private var captureRequestID: UUID?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        buildMenu()
        setupHotKey()
        setupSettings()

        let args = CommandLine.arguments
        if args.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.runDemo() }
        } else if args.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.show()
            }
        }

    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        captureRequestID = nil
        HotKeyManager.shared.unregister()
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapMark")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.toolTip = "SnapMark 截图"
        }
        statusItem = item
    }

    private func buildMenu() {
        let m = NSMenu()

        let capture = NSMenuItem(title: "截图", action: #selector(menuCapture), keyEquivalent: "")
        capture.target = self
        m.addItem(capture)
        captureItem = capture

        let settings = NSMenuItem(title: "设置快捷键…", action: #selector(menuSettings), keyEquivalent: "")
        settings.target = self
        m.addItem(settings)

        m.addItem(.separator())

        let perm = NSMenuItem(title: "屏幕录制权限…", action: #selector(menuPermission), keyEquivalent: "")
        perm.target = self
        m.addItem(perm)
        permissionItem = perm

        let relaunch = NSMenuItem(title: "重新启动 SnapMark", action: #selector(menuRelaunch), keyEquivalent: "")
        relaunch.target = self
        m.addItem(relaunch)

        m.addItem(.separator())

        let quit = NSMenuItem(title: "退出 SnapMark", action: #selector(menuQuit), keyEquivalent: "")
        quit.target = self
        m.addItem(quit)

        menu = m
        updateMenuTitles()
    }

    private func updateMenuTitles() {
        captureItem?.title = "截图（\(HotKeyManager.shared.combo.displayString)）"
        permissionItem?.title = ScreenCapture.hasPermission()
            ? "屏幕录制权限：已授权"
            : "屏幕录制权限：未授权（点这里开启）"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        updateMenuTitles()
        guard let menu else { return }
        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuCapture() { startCapture() }
    @objc private func menuSettings() { SettingsWindowController.shared.show() }
    @objc private func menuPermission() {
        _ = ScreenCapture.requestPermission()
        ScreenCapture.openPrivacySettings()
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuRelaunch() { relaunchApp() }

    // MARK: 快捷键

    private func setupHotKey() {
        HotKeyManager.shared.install { [weak self] in self?.startCapture() }

        let saved = HotKeyManager.shared.combo
        if !HotKeyManager.shared.register(saved) {
            // 保存的快捷键被占用了，退回默认
            if HotKeyManager.shared.register(.default) {
                HotKeyStore.save(.default)
            }
        }
        updateMenuTitles()
    }

    @discardableResult
    private func applyHotKey(_ combo: HotKeyCombo, persist: Bool) -> Bool {
        let previous = HotKeyManager.shared.combo
        if HotKeyManager.shared.register(combo) {
            if persist { HotKeyStore.save(combo) }
            updateMenuTitles()
            return true
        }
        // 被占用了，退回上一个可用的组合，避免把用户的快捷键搞丢
        HotKeyManager.shared.register(previous)
        return false
    }

    private func setupSettings() {
        SettingsWindowController.shared.applyHandler = { [weak self] combo in
            self?.applyHotKey(combo, persist: true) ?? false
        }
    }

    // MARK: 截图流程

    func startCapture() {
        guard controller == nil, !capturing else { return }
        guard let screen = ScreenCapture.screenUnderMouse() else { return }

        // 没权限时直接走授权流程。不要"先抓一次再说"：
        // 未授权时 SCShareableContent 会一直等系统的授权框，画面就卡住了。
        guard ScreenCapture.hasPermission() else {
            promptForPermission()
            return
        }

        capturing = true
        let requestID = UUID()
        captureRequestID = requestID

        // ScreenCaptureKit 在权限状态变化、显示器休眠或热插拔时可能迟迟不回调。
        // 看门狗保证一次异常请求不会永久吞掉后续快捷键。
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.captureRequestID == requestID, self.capturing else { return }
            self.capturing = false
            self.captureRequestID = nil
            self.showAlert("截图超时", "没有及时拿到屏幕画面，请检查屏幕录制权限后再试。")
        }

        ScreenCapture.capture(screen: screen) { [weak self] outcome in
            guard let self, self.captureRequestID == requestID else { return }
            self.capturing = false
            self.captureRequestID = nil
            switch outcome {
            case .success(let image):
                self.present(screen: screen, image: image)
            case .noPermission:
                self.promptForPermission()
            case .failed:
                self.showAlert("截图失败", "没有拿到屏幕画面，稍后再试一次。")
            }
        }
    }

    private func present(screen: NSScreen, image: CGImage) {
        let c = OverlayController(screen: screen, image: image)
        c.onClose = { [weak self] in self?.controller = nil }
        c.onPinImage = { [weak self] image in self?.pinImage(image) }
        controller = c
        c.begin()
    }

    private func pinImage(_ image: CGImage) {
        let pin = PinnedImageController(image: image)
        pin.onClose = { [weak self] in
            self?.pinnedWindows.removeAll { $0 === pin }
        }
        pinnedWindows.append(pin)
        pin.show()
    }

    // MARK: 屏幕录制权限

    /// 没授权时的引导：先弹系统授权框，被拒了再引导去系统设置
    private func promptForPermission() {
        // 这个调用会弹出系统自带的授权框（用户点"允许"即授权）；已拒绝过则直接返回 false
        if ScreenCapture.requestPermission() || ScreenCapture.hasPermission() {
            askRestartToApply()
            return
        }

        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
        在「系统设置 → 隐私与安全性 → 屏幕录制」里把 SnapMark 打开。

        注意：授权后要重启 SnapMark 才生效（macOS 的机制，不是程序偷懒）。
        授权一次即可，之后升级、重新编译都不会再问。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "已授权，重启")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ScreenCapture.openPrivacySettings()
            watchPermission()
        case .alertSecondButtonReturn:
            relaunchApp()
        default:
            break
        }
    }

    /// 刚拿到权限，但当前进程里 SCK 的授权结果已被缓存，必须重启
    private func askRestartToApply() {
        let alert = NSAlert()
        alert.messageText = "权限已开启"
        alert.informativeText = "macOS 要求重启应用后才生效。重启这一次，以后就不会再问了。"
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { relaunchApp() }
    }

    /// 在系统设置里勾选后自动检测，生效就自己重启，不用再去菜单里找
    private func watchPermission() {
        permissionTimer?.invalidate()
        var ticks = 0
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            ticks += 1
            if ScreenCapture.hasPermission() {
                timer.invalidate()
                self.permissionTimer = nil
                self.relaunchApp()
            } else if ticks > 180 {
                timer.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    private func relaunchApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: 演示（仅开发自检）

    private func runDemo() {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let scale: CGFloat = 2
        let size = NSSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        guard let base = DemoAssets.image(size: size) else { return }

        let c = OverlayController(screen: screen, image: base)
        c.onClose = { [weak self] in self?.controller = nil }
        controller = c
        c.begin()

        guard !CommandLine.arguments.contains("--noselect") else { return }
        let sel = NSRect(x: screen.frame.width * 0.18,
                         y: screen.frame.height * 0.30,
                         width: 620, height: 340)
        let list = DemoAssets.sampleAnnotations(in: sel)
        c.preset(selection: sel, annotations: list)
        if CommandLine.arguments.contains("--palette") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { c.openPaletteForTest() }
        }
    }
}

// MARK: 入口

let cliArgs = CommandLine.arguments
if cliArgs.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

if cliArgs.contains("--capture-test") {
    // 检查真实抓屏分辨率（需要屏幕录制权限）
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard let screen = NSScreen.screens.first else { print("no screen"); exit(1) }
        print("screen points=\(screen.frame.width)x\(screen.frame.height) backingScale=\(screen.backingScaleFactor)")
        print("hasPermission=\(ScreenCapture.hasPermission())")
        if !ScreenCapture.hasPermission() {
            try? "noPermission".write(toFile: "/tmp/snapmark-capture-result.txt", atomically: true, encoding: .utf8)
            print("CAPTURE FAILED: no permission")
            exit(2)
        }
        ScreenCapture.capture(screen: screen) { outcome in
            func report(_ s: String) { try? s.write(toFile: "/tmp/snapmark-capture-result.txt", atomically: true, encoding: .utf8) }
            switch outcome {
            case .noPermission:
                report("noPermission"); print("CAPTURE FAILED: no permission"); exit(2)
            case .failed:
                report("failed"); print("CAPTURE FAILED"); exit(3)
            case .success(let img):
                report("ok \(img.width)x\(img.height)")
                let wantW = Int((screen.frame.width * screen.backingScaleFactor).rounded())
                print("captured=\(img.width)x\(img.height)  expect>=\(wantW)")
                print("ratio=\(Double(img.width) / Double(screen.frame.width))")
                if let d = OverlayView.encode(img, type: "public.png" as CFString, properties: nil),
                   let url = URL(string: "file:///tmp/snapmark-capture-test.png") {
                    try? d.write(to: url)
                    print("saved /tmp/snapmark-capture-test.png")
                }
                exit(0)
            }
        }
    }
    app.run()
}

if cliArgs.contains("--cursor-probe") {
    // 只用来看"覆盖层刚出现、鼠标还没动"时的光标真实身份
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var keep: OverlayController?
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        guard let screen = NSScreen.screens.first,
              let base = DemoAssets.image(size: NSSize(width: screen.frame.width * 2,
                                                       height: screen.frame.height * 2))
        else { print("probe setup failed"); exit(1) }
        let c = OverlayController(screen: screen, image: base)
        keep = c
        c.begin()
        let known: [(String, NSCursor)] = [("arrow", .arrow), ("crosshair", .crosshair),
                                           ("iBeam", .iBeam), ("openHand", .openHand),
                                           ("closedHand", .closedHand)]
        if cliArgs.contains("--nudge") {
            // 假设：鼠标静止时窗口服务器不重算光标，用 2px 的来回 warp 触发一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let p = NSEvent.mouseLocation
                let h = NSScreen.screens.first?.frame.height ?? 0
                CGWarpMouseCursorPosition(CGPoint(x: p.x + 2, y: h - p.y))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    CGWarpMouseCursorPosition(CGPoint(x: p.x, y: h - p.y))
                }
            }
        }
        for t in [0.3, 1.0, 2.0, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                let cur = NSCursor.current
                let name = known.first { $0.1 === cur }?.0 ?? "unknown"
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
                print("t=\(t)s cursor=\(name) isActive=\(NSApp.isActive) key=\(NSApp.keyWindow != nil) front=\(front) mouse=\(NSEvent.mouseLocation)")
                if t > 3 { _ = keep; exit(0) }
            }
        }
    }
    app.run()
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
