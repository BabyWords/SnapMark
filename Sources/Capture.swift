import AppKit
import ScreenCaptureKit

enum CaptureOutcome {
    case success(CGImage)
    case noPermission
    case failed
}

enum ScreenCapture {

    // MARK: 权限

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 屏幕

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(n.uint32Value)
    }

    static func screenUnderMouse() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        // 1) 优先用 CoreGraphics 的全局鼠标位置 + CGDisplayBounds（同为“主屏左上角原点、y 向下”），
        //    最底层、最实时，避免 AppKit 坐标在多屏排列下可能的不一致。
        if let cgMouse = CGEvent(source: nil)?.location {
            for screen in screens {
                if let id = displayID(of: screen), CGDisplayBounds(id).contains(cgMouse) {
                    return screen
                }
            }
        }

        // 2) 兜底：用 AppKit 坐标（NSEvent.mouseLocation + NSScreen.frame，同为“主屏左下角原点、y 向上”）
        let nsMouse = NSEvent.mouseLocation
        if let hit = screens.first(where: { $0.frame.contains(nsMouse) }) {
            return hit
        }

        // 3) 都没命中（鼠标在屏幕间隙 / 显示器热插拔）时，取中心距鼠标最近的屏幕
        var best: NSScreen?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for s in screens {
            let dx = nsMouse.x - s.frame.midX
            let dy = nsMouse.y - s.frame.midY
            let d = dx * dx + dy * dy
            if d < bestDist { bestDist = d; best = s }
        }
        return best ?? NSScreen.main
    }

    // MARK: 截图

    /// 抓取整块屏幕，回调在主线程。
    /// 不再调 `screencapture` 子进程兜底：子进程继承的是本 App 的授权，
    /// 没权限时会再弹一次系统授权框，造成"已经给过权限还反复弹窗"。
    static func capture(screen: NSScreen, excludingWindowID: CGWindowID? = nil,
                        completion: @escaping (CaptureOutcome) -> Void) {
        // NSScreen 属于 AppKit 主线程对象：先在调用线程提取值类型，
        // 异步任务只携带 displayID/尺寸，避免后台读取 NSScreen 触发竞态。
        guard let id = displayID(of: screen) else { completion(.failed); return }
        let scale = screen.backingScaleFactor
        let wantW = Int((screen.frame.width * scale).rounded())
        let wantH = Int((screen.frame.height * scale).rounded())

        if #available(macOS 14.0, *) {
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first(where: { $0.displayID == id }) else {
                        await finish(excludingWindowID == nil ? legacyCapture(displayID: id) : .failed, completion)
                        return
                    }
                    let excludedWindows: [SCWindow]
                    if let excludingWindowID {
                        guard let hintWindow = content.windows.first(where: { $0.windowID == excludingWindowID }) else {
                            await finish(.failed, completion)
                            return
                        }
                        excludedWindows = [hintWindow]
                    } else {
                        excludedWindows = []
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
                    let cfg = SCStreamConfiguration()
                    // 按点尺寸 × 屏幕缩放要像素尺寸，避免拿到 1x 画面被放大后发虚。
                    // SCDisplay.width 在当前系统返回点数，故不能简单按 display.width 取 min。
                    cfg.width = max(display.width, wantW)
                    cfg.height = max(display.height, wantH)
                    cfg.showsCursor = false
                    cfg.captureResolution = .best
                    do {
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                        await finish(.success(image), completion)
                    } catch {
                        await finish(excludingWindowID == nil ? legacyCapture(displayID: id) : .failed, completion)
                    }
                } catch {
                    // 没权限时 SCShareableContent 抛 -3801，直接给权限提示，不做无意义兜底
                    let denied = isPermissionError(error) || !hasPermission()
                    let fallback = excludingWindowID == nil ? legacyCapture(displayID: id) : .failed
                    await finish(denied ? .noPermission : fallback, completion)
                }
            }
        } else {
            completion(legacyCapture(displayID: id))
        }
    }

    /// 权限被拒绝时 ScreenCaptureKit 抛 -3801（userDeclined）
    private static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        return e.code == -3801 || e.code == -3802
    }

    /// 旧版 CG 接口兜底（同样要权限，失败就按权限问题处理）
    private static func legacyCapture(displayID id: CGDirectDisplayID) -> CaptureOutcome {
        if let img = CGDisplayCreateImage(id) { return .success(img) }
        return hasPermission() ? .failed : .noPermission
    }

    private static func finish(_ outcome: CaptureOutcome, _ completion: @escaping (CaptureOutcome) -> Void) async {
        await MainActor.run { completion(outcome) }
    }
}
