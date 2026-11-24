import AppKit
import AVFoundation
import Carbon.HIToolbox
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var captureItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var stopScrollItem: NSMenuItem?
    private var recordFullscreenItem: NSMenuItem?
    private var recordSelectionItem: NSMenuItem?
    private var stopRecordingItem: NSMenuItem?
    private var videoRecorder: VideoRecorder?
    private var isStoppingRecording = false
    private var quitAfterRecording = false
    private var recordHintWindow: NSWindow?
    private var controller: OverlayController?
    private var pinnedWindows: [PinnedImageController] = []
    private var scrollCapture: ScrollCaptureController?
    private var capturing = false
    private var captureRequestID: UUID?
    private var permissionTimer: Timer?
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        buildMenu()
        setupHotKey()
        setupSettings()

        // Sparkle 自动更新：从 Info.plist 的 SUFeedURL 拉取更新源，定期检查。
        // 需持有引用，否则控制器被释放后自动更新会失效。
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let args = CommandLine.arguments
        if args.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.runDemo() }
        } else if args.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.show()
            }
        }

    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = videoRecorder else { return .terminateNow }
        quitAfterRecording = true
        if !isStoppingRecording {
            isStoppingRecording = true
            recorder.stop()
            updateRecordingMenu()
            setRecordingIndicator("正在结束录屏")
        }
        return .terminateCancel
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
            let img = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "SnapMark")
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
        // 关闭自动启用/禁用，让 updateRecordingMenu 里手动设置的 isEnabled/isHidden 生效。
        // 默认 autoenablesItems=true 会在菜单显示前把所有 target 可响应的 item 重新启用，
        // 导致录制时“录制当前屏幕/选择区域录制”无法置灰。
        m.autoenablesItems = false

        let capture = NSMenuItem(title: "截图", action: #selector(menuCapture), keyEquivalent: "")
        capture.target = self
        m.addItem(capture)
        captureItem = capture

        let recordFullscreen = NSMenuItem(title: "录制当前屏幕", action: #selector(menuRecordFullscreen), keyEquivalent: "")
        recordFullscreen.target = self
        m.addItem(recordFullscreen)
        recordFullscreenItem = recordFullscreen

        let recordSelection = NSMenuItem(title: "选择区域录制…", action: #selector(menuRecordSelection), keyEquivalent: "")
        recordSelection.target = self
        m.addItem(recordSelection)
        recordSelectionItem = recordSelection

        let stopRecording = NSMenuItem(title: "停止录屏", action: #selector(menuStopRecording), keyEquivalent: "")
        stopRecording.target = self
        stopRecording.isHidden = true
        m.addItem(stopRecording)
        stopRecordingItem = stopRecording

        let stopScroll = NSMenuItem(title: "停止长截图", action: #selector(menuStopScrollCapture), keyEquivalent: "")
        stopScroll.target = self
        stopScroll.isHidden = true
        m.addItem(stopScroll)
        stopScrollItem = stopScroll

        let settings = NSMenuItem(title: "设置快捷键…", action: #selector(menuSettings), keyEquivalent: "")
        settings.target = self
        m.addItem(settings)

        m.addItem(.separator())

        let perm = NSMenuItem(title: "屏幕录制权限…", action: #selector(menuPermission), keyEquivalent: "")
        perm.target = self
        m.addItem(perm)
        permissionItem = perm

        let checkUpdates = NSMenuItem(title: "检查更新…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        m.addItem(checkUpdates)

        let relaunch = NSMenuItem(title: "重新启动 SnapMark", action: #selector(menuRelaunch), keyEquivalent: "")
        relaunch.target = self
        m.addItem(relaunch)

        m.addItem(.separator())

        let about = NSMenuItem(title: "关于 SnapMark", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        m.addItem(about)

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
        updateRecordingMenu()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        updateMenuTitles()
        guard let menu else { return }
        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuCapture() { startCapture() }
    @objc private func menuRecordFullscreen() {
        startCapture(forRecording: true, presetFullscreen: true)
    }
    @objc private func menuRecordSelection() { startCapture(forRecording: true) }
    @objc private func menuStopRecording() { stopRecording() }
    @objc private func menuStopScrollCapture() { stopScrollCapture() }
    @objc private func menuSettings() { SettingsWindowController.shared.show() }
    @objc private func menuPermission() {
        _ = ScreenCapture.requestPermission()
        ScreenCapture.openPrivacySettings()
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuRelaunch() { relaunchApp() }
    @objc private func menuCheckForUpdates() { updaterController?.updater.checkForUpdates() }
    @objc private func menuAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        showAlert("SnapMark", "版本 \(version)\n\n原生 macOS 截图、长截图与录屏工具。")
    }

    // MARK: 快捷键

    private func setupHotKey() {
        HotKeyManager.shared.install { [weak self] in
            guard let self else { return }
            if self.scrollCapture != nil { self.stopScrollCapture() }
            else { self.startCapture() }
        }

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

    func startCapture(forRecording: Bool = false, presetFullscreen: Bool = false) {
        guard controller == nil, !capturing, videoRecorder == nil, scrollCapture == nil else { return }
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
                self.present(screen: screen, image: image, forRecording: forRecording, presetFullscreen: presetFullscreen)
            case .noPermission:
                self.promptForPermission()
            case .failed:
                self.showAlert("截图失败", "没有拿到屏幕画面，稍后再试一次。")
            }
        }
    }

    private func present(screen: NSScreen, image: CGImage, forRecording: Bool = false, presetFullscreen: Bool = false) {
        let preset: NSRect? = presetFullscreen ? NSRect(origin: .zero, size: screen.frame.size) : nil
        let c = OverlayController(screen: screen, image: image, recordsSelectionOnRelease: forRecording,
                                  presetSelection: preset, audioConfig: currentAudioConfig())
        c.onClose = { [weak self] in self?.controller = nil }
        c.onPinImage = { [weak self] image, size in self?.pinImage(image, size: size) }
        c.onRecordSelection = { [weak self, weak c] region, config in
            guard let self, let c, self.videoRecorder == nil, self.scrollCapture == nil else { return }
            Self.saveAudioConfig(config)
            c.close()
            self.controller = nil
            self.startRecording(screen: screen, region: region, config: config)
        }
        c.onScrollCapture = { [weak self, weak c] region, vertical in
            guard let self, let c else { return }
            self.startScrollCapture(screen: screen, region: region, vertical: vertical, overlay: c)
        }
        controller = c
        c.begin()
        if forRecording {
            c.onClose = { [weak self] in
                self?.controller = nil
                if self?.videoRecorder == nil { self?.statusItem?.button?.toolTip = "SnapMark 截图" }
            }
        }
    }

    private func startScrollCapture(screen: NSScreen, region: NSRect, vertical: Bool, overlay: OverlayController) {
        guard scrollCapture == nil else { return }
        overlay.hideForScrollCapture(selection: region)
        let capture = ScrollCaptureController(screen: screen, region: region,
                                              axis: vertical ? .vertical : .horizontal,
                                              excludingWindowID: overlay.scrollHintWindowID)
        capture.onStatus = { [weak self] message in
            self?.statusItem?.button?.toolTip = message
        }
        capture.onFinish = { [weak self, weak overlay] image in
            guard let self else { return }
            self.scrollCapture = nil
            self.stopScrollItem?.isHidden = true
            self.statusItem?.button?.toolTip = "SnapMark 截图"
            guard let image else {
                overlay?.showAfterScrollCapture()
                self.showAlert("长截图失败", "没有采集到足够画面。请确保区域可滚动并重新尝试。")
                return
            }
            overlay?.close()
            let pointSize = NSSize(width: CGFloat(image.width) / screen.backingScaleFactor,
                                   height: CGFloat(image.height) / screen.backingScaleFactor)
            self.pinImage(image, size: pointSize)
        }
        scrollCapture = capture
        stopScrollItem?.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { capture.start() }
    }

    private func stopScrollCapture() {
        scrollCapture?.stop()
    }

    // MARK: 视频录制

    private static let audioSourceKey = "recordingAudioSource"
    private static let microphoneDeviceKey = "recordingMicrophoneDeviceID"

    /// 读取用户上次选择的声音配置；从未选择时默认“系统声音”。
    private func currentAudioConfig() -> RecordingAudioConfig {
        let source: RecordingAudioSource
        if UserDefaults.standard.object(forKey: Self.audioSourceKey) == nil {
            source = .system
        } else {
            source = RecordingAudioSource(rawValue: UserDefaults.standard.integer(forKey: Self.audioSourceKey)) ?? .system
        }
        let micID = UserDefaults.standard.string(forKey: Self.microphoneDeviceKey)
        return RecordingAudioConfig(source: source, microphoneDeviceID: micID)
    }

    private static func saveAudioConfig(_ config: RecordingAudioConfig) {
        UserDefaults.standard.set(config.source.rawValue, forKey: audioSourceKey)
        if let id = config.microphoneDeviceID {
            UserDefaults.standard.set(id, forKey: microphoneDeviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: microphoneDeviceKey)
        }
    }

    private func startRecording(screen: NSScreen, region: NSRect, config: RecordingAudioConfig) {
        guard videoRecorder == nil, scrollCapture == nil, controller == nil, !capturing else { return }
        guard ScreenCapture.hasPermission() else {
            promptForPermission()
            return
        }
        // 采集麦克风时先确保麦克风权限已授权，否则录出来没有声音。
        if config.capturesMicrophone {
            ensureMicrophonePermission { [weak self] granted in
                guard let self else { return }
                guard granted else {
                    self.showAlert("需要「麦克风」权限",
                                   "录屏要采集麦克风声音，请在「系统设置 → 隐私与安全性 → 麦克风」里打开 SnapMark，然后重试。")
                    return
                }
                self.beginRecording(screen: screen, region: region, config: config)
            }
            return
        }
        beginRecording(screen: screen, region: region, config: config)
    }

    private func ensureMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func beginRecording(screen: NSScreen, region: NSRect, config: RecordingAudioConfig) {
        let clipped = region.standardized.intersection(NSRect(origin: .zero, size: screen.frame.size))
        guard !clipped.isNull, clipped.width >= 16, clipped.height >= 16 else {
            showAlert("录屏区域太小", "请至少选择 16 × 16 点的区域。")
            return
        }
        do {
            let directory = SaveLocationStore.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let baseName = "SnapMark-Recording-\(formatter.string(from: Date()))"
            var output = directory.appendingPathComponent(baseName).appendingPathExtension("mp4")
            var suffix = 2
            while FileManager.default.fileExists(atPath: output.path) {
                output = directory.appendingPathComponent("\(baseName)-\(suffix)").appendingPathExtension("mp4")
                suffix += 1
            }
            // 先显示录制范围提示层（红框 + 压暗），并拿到它的窗口号，
            // 让录屏采集时通过 SCContentFilter 排除该窗口，红框只显示在屏幕上、不会进成片。
            showRecordHint(screen: screen, region: clipped)
            let excludingWindowID: CGWindowID? = {
                guard let number = recordHintWindow?.windowNumber, number > 0 else { return nil }
                return CGWindowID(number)
            }()
            let recorder = VideoRecorder(screen: screen, region: clipped, outputURL: output,
                                         excludingWindowID: excludingWindowID,
                                         audioSource: config.source,
                                         microphoneDeviceID: config.microphoneDeviceID)
            recorder.onStarted = { [weak self, weak recorder] in
                guard let self, self.videoRecorder === recorder else { return }
                self.setRecordingIndicator("录制中")
                self.updateRecordingMenu()
            }
            recorder.onFinish = { [weak self, weak recorder] result in
                guard let self else { return }
                self.hideRecordHint()
                if self.videoRecorder === recorder { self.videoRecorder = nil }
                self.isStoppingRecording = false
                self.stopRecordingItem?.isHidden = true
                self.updateRecordingMenu()
                self.setRecordingIndicator(nil)
                let shouldQuit = self.quitAfterRecording
                self.quitAfterRecording = false
                switch result {
                case .success(let url):
                    if shouldQuit {
                        NSApp.terminate(nil)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "录屏已保存"
                        alert.informativeText = url.path
                        alert.addButton(withTitle: "好")
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                case .failure(let error):
                    if shouldQuit {
                        NSApp.terminate(nil)
                    } else {
                        self.showAlert("录屏失败", error.localizedDescription)
                    }
                }
            }
            videoRecorder = recorder
            updateRecordingMenu()
            setRecordingIndicator("准备录制")
            recorder.start()
        } catch {
            showAlert("无法创建录屏文件", error.localizedDescription)
        }
    }

    private func stopRecording() {
        guard !isStoppingRecording else { return }
        isStoppingRecording = true
        videoRecorder?.stop()
        setRecordingIndicator("正在结束录屏")
        updateRecordingMenu()
    }

    private func showRecordHint(screen: NSScreen, region: NSRect) {
        hideRecordHint()
        let hint = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.hasShadow = false
        hint.level = .screenSaver
        hint.ignoresMouseEvents = true
        hint.acceptsMouseMovedEvents = false
        hint.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hint.contentView = RecordingRegionHintView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                                   region: region)
        recordHintWindow = hint
        hint.orderFrontRegardless()
    }

    private func hideRecordHint() {
        recordHintWindow?.orderOut(nil)
        recordHintWindow = nil
    }

    private func setRecordingIndicator(_ title: String?) {
        guard let button = statusItem?.button else { return }
        if let title {
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: title)
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = .systemRed
            button.toolTip = "SnapMark：\(title)"
        } else {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapMark")
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
            button.toolTip = "SnapMark 截图"
        }
    }

    private func updateRecordingMenu() {
        let active = videoRecorder != nil
        stopRecordingItem?.isHidden = !active
        stopRecordingItem?.isEnabled = active && !isStoppingRecording
        captureItem?.isEnabled = !active && !capturing && scrollCapture == nil
        recordFullscreenItem?.isEnabled = !active && !capturing && scrollCapture == nil
        recordSelectionItem?.isEnabled = !active && !capturing && scrollCapture == nil
    }

    private func pinImage(_ image: CGImage, size: NSSize) {
        let pin = PinnedImageController(image: image, pointSize: size)
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

if cliArgs.contains("--screen-probe") {
    // 诊断多屏：打印每块屏幕的 frame / CGDisplayBounds，以及鼠标在两种坐标系下的位置，
    // 用于排查“截图不跟随鼠标到副屏”的问题。需在有多显示器的机器上运行。
    let screens = NSScreen.screens
    print("屏幕数: \(screens.count)")
    for (i, s) in screens.enumerated() {
        let id = ScreenCapture.displayID(of: s).map { String($0) } ?? "-"
        let cg = ScreenCapture.displayID(of: s).map { "\(CGDisplayBounds($0))" } ?? "-"
        print("屏\(i): id=\(id) NS.frame=\(s.frame) CG.bounds=\(cg) scale=\(s.backingScaleFactor) main=\(s == NSScreen.main)")
    }
    print("NS 鼠标位置(NSEvent): \(NSEvent.mouseLocation)")
    print("CG 鼠标位置(CGEvent): \(CGEvent(source: nil)?.location ?? .zero)")
    print("screenUnderMouse 结果: \(ScreenCapture.screenUnderMouse()?.frame ?? .zero)")
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
