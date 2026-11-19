# SnapMark

SnapMark 是一款原生 macOS 菜单栏截图工具，基于 Swift、AppKit、ScreenCaptureKit 和 Vision 构建。它支持截图、标注、OCR 文字选择、置顶预览、四方向长截图，以及带声音选项的 MP4 录屏。

SnapMark is a native macOS menu-bar screenshot tool built with Swift, AppKit, ScreenCaptureKit, and Vision. It supports screenshots, annotation, OCR text selection, pinned previews, four-direction scrolling capture, and MP4 screen recording with audio options.

## 功能 / Features

### 截图与选区 / Screenshot & Selection

- 从菜单栏选择“截图”，或使用全局截图快捷键启动；默认快捷键为 `⌘⇧X`，可在“设置快捷键…”中修改。
- 按住 `Shift` 拖动可创建正方形选区。选区可以移动，也可以拖动八个边缘/角点手柄调整大小；方向键可微调位置。
- 选区处理工具栏提供选择、箭头、矩形、椭圆、画笔、文字、马赛克和识别文字等工具，并可更改标注颜色。
- 按 `Esc` 或在截图界面按鼠标右键可取消当前截图操作。

- Launch from the menu bar's "Screenshot" item or via a global hotkey; the default is `⌘⇧X` and can be changed in "Set Hotkey…".
- Hold `Shift` while dragging to create a square selection. Selections can be moved, resized via the eight edge/corner handles, and nudged with the arrow keys.
- The selection toolbar offers select, arrow, rectangle, ellipse, pen, text, mosaic, and text-recognition tools, plus annotation color controls.
- Press `Esc` or right-click while the capture UI is up to cancel.

### 标注、文字识别与撤销 / Annotation, OCR & Undo

- 通过箭头、矩形、椭圆、画笔、文字和马赛克标注截图；标注会合成到复制或保存的图片中。
- 箭头工具提供三种样式：细箭头、粗箭头和渐变粗箭头（锥形，从细到粗）。点击箭头工具会弹出样式选择，选中后即可在选区内拖拽绘制箭头。
- 点击“识别文字”进入 OCR 选择模式。SnapMark 使用 Apple Vision 的精确识别级别识别中英文；可拖选单个字符、行内片段或跨行内容，然后按 `⌘C` 复制。双击可选择全部识别文字；再次点击识别工具或选择其他工具可退出该模式。
- `⌘Z` 可撤销选区重选、移动、缩放、标注和文字输入等操作。

- Annotate with arrows, rectangles, ellipses, pen, text, and mosaic; annotations are composited into the copied or saved image.
- The arrow tool offers three styles: thin, thick, and tapered (a gradient arrow that goes from thin to thick). Clicking the arrow tool pops up a style picker; pick one and drag to draw an arrow in the selection.
- Click "Recognize Text" to enter OCR selection mode. SnapMark uses Apple Vision's accurate recognition level for Chinese and English; drag to select individual characters, inline fragments, or cross-line content, then press `⌘C` to copy. Double-click selects all recognized text; click the recognition tool again or choose another tool to exit.
- `⌘Z` undoes selection, moving, resizing, annotation, and text input actions.

### 复制、保存与置顶 / Copy, Save & Pin

- 使用工具栏按钮将当前截图（含标注）复制到剪贴板，或保存为 PNG。
- “设置快捷键…”窗口同时提供保存位置设置。默认位置为“下载”文件夹；可选其他文件夹，也可恢复默认。截图、置顶图片保存和录屏共用该位置。
- 点击图钉按钮可将截图作为置顶悬浮图片显示，并结束当前截图处理。悬浮图可拖动；右键选择“保存”或“销毁”。

- Use the toolbar buttons to copy the current screenshot (with annotations) to the clipboard or save it as PNG.
- The "Set Hotkey…" window also provides a save-location setting. The default is the Downloads folder; you can choose another folder or restore the default. Screenshots, pinned images, and recordings share this location.
- Click the pin button to show the screenshot as a floating always-on-top image and finish the capture session. The floating image can be dragged; right-click to "Save" or "Destroy".

### 纵向与横向长截图 / Vertical & Horizontal Scrolling Capture

1. 框选可滚动内容区域。
2. 点击工具栏的纵向或横向长截图按钮。采集期间，选区边界会保持可见，目标应用仍可接收滚动输入。
3. 在选区内缓慢滚动。程序自动判断上/下或左/右方向，并根据相邻画面的重叠内容拼接；滚动过程中改变方向也会尝试继续拼接。
4. 再次按截图快捷键，或从菜单栏选择“停止长截图”结束。完成结果会以置顶预览显示，可右键保存或销毁。

1. Select the scrollable content area.
2. Click the vertical or horizontal scrolling-capture button. During capture, the selection border stays visible and the target app still receives scroll input.
3. Scroll slowly inside the selection. SnapMark automatically detects the up/down or left/right direction and stitches frames by matching overlapping content; changing direction mid-scroll is also handled.
4. Press the screenshot hotkey again, or choose "Stop Scrolling Capture" from the menu bar, to finish. The result appears as a pinned preview you can save or destroy.

长截图建议缓慢、连续滚动，避免快速跳过画面。对空白、重复或无法可靠匹配的帧，程序会保守跳过，以降低错误位移导致正文重复的风险。

Scroll slowly and continuously, avoiding skipping large chunks of content. Blank, repetitive, or unreliable frames are conservatively skipped to reduce the risk of duplicated content.

### 屏幕录制 / Screen Recording

- 打开菜单栏 SnapMark 菜单，选择“录制当前屏幕”或“选择区域录制…”。框选（或确认整个屏幕）后，会出现“开始录制”按钮，点击确认后才开始录制；`Esc` 或右键可取消。
- 录制期间会在录制区域显示红色范围边框并压暗区域外画面，方便确认正在录制的范围；该提示层会被采集排除，不会出现在成片里。
- 录制输出为 H.264 编码的 MP4。点击「开始录制」旁的下拉菜单可选择声音来源：静音、系统声音、麦克风，或系统声音 + 麦克风。文件保存到当前配置的保存位置，并使用带日期时间的文件名。
- 录制时菜单栏显示录制状态，且“录制当前屏幕 / 选择区域录制”会置灰；从菜单栏选择“停止录屏”正常结束并显示保存位置。录制过程中退出应用时会先结束录制。

- Open the menu-bar SnapMark menu and choose "Record Current Screen" or "Select Region to Record…". After selecting a region (or confirming the full screen), a "Start Recording" button appears; recording only begins after you confirm. Press `Esc` or right-click to cancel.
- While recording, the captured region is outlined in red and the area outside is dimmed to show exactly what is being recorded; this overlay is excluded from the capture and does not appear in the output.
- Recordings are H.264-encoded MP4. Choose the audio source from the dropdown next to the "Start Recording" button: mute, system audio, microphone, or system audio + microphone. Files are saved to the configured save location with a timestamped filename.
- The menu bar shows recording status, and the "Record Current Screen / Select Region to Record" items are greyed out during recording. Choose "Stop Recording" from the menu bar to finish. Recording is stopped automatically if the app quits.

## 系统要求 / System Requirements

- macOS 14 或更新版本 / macOS 14 or later
- Apple Silicon（当前构建目标为 `arm64`）/ Apple Silicon (current build target is `arm64`)

## 下载 / Download

最新版本及历史版本均发布在 GitHub Releases。The latest version and all previous versions are published on GitHub Releases:

- 最新版 / Latest: https://github.com/BabyWords/SnapMark/releases/latest
- 全部版本 / All releases: https://github.com/BabyWords/SnapMark/releases

## 自动更新 / Automatic Updates

SnapMark 支持自动更新：应用启动后会定期检查新版本，发现更新时提示下载并自动安装。

SnapMark supports automatic updates: the app periodically checks for new versions and prompts to download and install them automatically.

## 屏幕录制权限 / Screen Recording Permission

截图、长截图和录屏均需要 macOS 屏幕录制权限。首次使用时按提示前往“系统设置 → 隐私与安全性 → 屏幕录制”授权 SnapMark；也可以在菜单栏权限菜单项中打开设置。授权状态变化后，必要时按提示重新启动应用。录制麦克风声音时，还需要「麦克风」权限（系统设置 → 隐私与安全性 → 麦克风）。

Screenshots, scrolling capture, and recording all require the macOS Screen Recording permission. On first use, follow the prompt to "System Settings → Privacy & Security → Screen Recording" and grant access to SnapMark; you can also open the setting from the menu-bar permission item. Restart the app if prompted after the permission changes. Recording microphone audio also requires the Microphone permission (System Settings → Privacy & Security → Microphone).

## 签名风险 / Signing Risk

> ⚠️ 本应用使用本地自签名证书签名，**没有 Apple Developer ID 证书，也未经过 Apple 公证（notarization）**。
> ⚠️ This app is signed with a local self-signed certificate — it has **no Apple Developer ID certificate and has not been notarized by Apple**.

因此 macOS 的 Gatekeeper 会将其标记为“无法验证的开发者”或“来自身份不明的开发者”。首次在每台 Mac 上安装时需要手动放行一次：

As a result, macOS Gatekeeper will flag it as an "unverified developer" or "unidentified developer". On each Mac, you need to allow it once:

1. 右键点击应用 → “打开”（而不是直接双击），或在“系统设置 → 隐私与安全性”中点击“仍要打开”。
2. 首次截图/录屏时，在“系统设置 → 隐私与安全性 → 屏幕录制”勾选 SnapMark 授权。

1. Right-click the app → "Open" (instead of double-clicking), or click "Open Anyway" in "System Settings → Privacy & Security".
2. On the first screenshot/recording, enable SnapMark under "System Settings → Privacy & Security → Screen Recording".

放行一次后即可正常使用，后续自动更新不再弹窗。此方案适合个人自有设备（无费用）；如需公开分发或彻底消除 Gatekeeper 警告，需购买 Apple Developer 账号（$99/年）并使用 Developer ID 证书签名 + 公证。

After allowing it once, it runs normally and subsequent automatic updates no longer prompt. This approach is free and suitable for personal devices; to distribute publicly or fully eliminate Gatekeeper warnings, an Apple Developer account ($99/year) with Developer ID signing and notarization is required.

## 隐私说明 / Privacy

屏幕截图与录屏由 macOS 屏幕捕获 API 获取；文字识别通过 Apple Vision 在本机执行。项目没有配置将截图、录屏或 OCR 内容上传至远程服务的逻辑。

Screen capture and recording use the macOS screen-capture APIs; text recognition runs locally via Apple Vision. The project has no logic that uploads screenshots, recordings, or OCR content to any remote service.

## 许可 / License

当前仓库未附带开源许可证。公开可见不等同于授予他人复制、修改或分发代码的许可；如计划开放使用，请补充适合的许可证文件。

This repository currently ships without an open-source license. Being publicly visible does not grant others permission to copy, modify, or distribute the code; add an appropriate license file if you plan to open it up.
