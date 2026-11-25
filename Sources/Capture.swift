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

        let p = NSEvent.mouseLocation
        if let hit = screens.first(where: { $0.frame.contains(p) }) {
            return hit
        }

        // 兜底：鼠标落在屏幕间隙 / 显示器热插拔时，取中心距鼠标最近的屏幕
        var best: NSScreen?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for s in screens {
            let dx = p.x - s.frame.midX
            let dy = p.y - s.frame.midY
            let d = dx * dx + dy * dy
            if d < bestDist { bestDist = d; best = s }
        }
        return best ?? NSScreen.main
    }

    /// 命中全局坐标点（AppKit 坐标，主屏左下角原点）所在的屏幕。
    static func screen(containingGlobalPoint p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) }
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

    /// 抓取所有屏幕，并合成一张覆盖全部显示器的位图。
    /// 返回的 bbox 是所有 `NSScreen.frame` 的并集（AppKit 全局坐标，主屏左下角原点、y 向上）；
    /// 合成图原点对齐 bbox 左下角，屏幕之间的间隙填充黑色。
    /// 统一使用最大的 backingScaleFactor 作为 imageScale，保证高分辨率屏不被降采样。
    /// 注意：不能走 `CGDisplayCreateImage`——它在授权后仍可能返回全黑图，只有 ScreenCaptureKit 能真正截到内容。
    static func captureAllScreens(completion: @escaping (NSRect, CGImage?) -> Void) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { completion(.zero, nil); return }

        // 主线程提取每块屏的 frame / displayID / scale，异步任务只携带值类型，
        // 避免在后台读取 NSScreen 对象触发竞态。
        let targets: [(frame: NSRect, id: CGDirectDisplayID, scale: CGFloat)] = screens.compactMap { s in
            guard let id = displayID(of: s) else { return nil }
            return (s.frame, id, s.backingScaleFactor)
        }
        guard !targets.isEmpty else { completion(.zero, nil); return }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let displays = content.displays

                var bbox = targets[0].frame
                for t in targets { bbox = bbox.union(t.frame) }

                let unified = max(1, targets.map { $0.scale }.max() ?? 1)
                let pxW = max(1, Int((bbox.width * unified).rounded()))
                let pxH = max(1, Int((bbox.height * unified).rounded()))
                guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    await finishAll(.zero, nil, completion)
                    return
                }

                // 间隙区域填黑（这些区域不会被正常框选到）
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pxW), height: CGFloat(pxH)))
                ctx.interpolationQuality = .high

                var capturedCount = 0
                for t in targets {
                    var img: CGImage? = nil
                    if let display = displays.first(where: { $0.displayID == t.id }) {
                        let cfg = SCStreamConfiguration()
                        cfg.showsCursor = false
                        cfg.captureResolution = .best
                        // SCDisplay.width/height 返回的是点数，这里显式按像素尺寸设置，确保拿全分辨率
                        let wantW = Int((t.frame.width * t.scale).rounded())
                        let wantH = Int((t.frame.height * t.scale).rounded())
                        cfg.width = max(display.width, wantW)
                        cfg.height = max(display.height, wantH)
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        img = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                          configuration: cfg)
                    }
                    // 兜底：SCShareableContent 的 displayID 与 NSScreenNumber 不一致、或
                    // SCScreenshotManager 截图失败时，退回 CGDisplayCreateImage。
                    // 真实显示器上有屏幕录制权限即可截到内容（无头/虚拟环境除外）。
                    if img == nil { img = CGDisplayCreateImage(t.id) }
                    guard let img else { continue }
                    capturedCount += 1
                    let dx = (t.frame.minX - bbox.minX) * unified
                    let dy = (t.frame.minY - bbox.minY) * unified
                    let w = t.frame.width * unified
                    let h = t.frame.height * unified
                    ctx.draw(img, in: CGRect(x: dx, y: dy, width: w, height: h))
                }

                // 一块屏都没截到（显示器列表异常等），返回 nil 让上层回退到单屏截图
                let combined = capturedCount > 0 ? ctx.makeImage() : nil
                await finishAll(bbox, combined, completion)
            } catch {
                await finishAll(.zero, nil, completion)
            }
        }
    }

    private static func finishAll(_ bbox: NSRect, _ image: CGImage?,
                                  _ completion: @escaping (NSRect, CGImage?) -> Void) async {
        await MainActor.run { completion(bbox, image) }
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
