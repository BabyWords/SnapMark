# SnapMark

SnapMark is a native macOS menu-bar screenshot tool built with Swift, AppKit, ScreenCaptureKit, and Vision. It supports screenshots, annotation, OCR text selection, pinned previews, four-direction scrolling capture, and audio-free MP4 screen recording.

## Features

### Screenshot & Selection

- Launch from the menu bar's "Screenshot" item or via a global hotkey; the default is `⌘⇧X` and can be changed in "Set Hotkey…".
- Hold `Shift` while dragging to create a square selection. Selections can be moved, resized via the eight edge/corner handles, and nudged with the arrow keys.
- The selection toolbar offers select, arrow, rectangle, ellipse, pen, text, mosaic, and text-recognition tools, plus annotation color controls.
- Press `Esc` or right-click while the capture UI is up to cancel.

### Annotation, OCR & Undo

- Annotate with arrows, rectangles, ellipses, pen, text, and mosaic; annotations are composited into the copied or saved image.
- The arrow tool offers three styles: thin, thick, and tapered (a gradient arrow that goes from thin to thick). Clicking the arrow tool pops up a style picker; pick one and drag to draw an arrow in the selection.
- Click "Recognize Text" to enter OCR selection mode. SnapMark uses Apple Vision's accurate recognition level for Chinese and English; drag to select individual characters, inline fragments, or cross-line content, then press `⌘C` to copy. Double-click selects all recognized text; click the recognition tool again or choose another tool to exit.
- `⌘Z` undoes selection, moving, resizing, annotation, and text input actions.

### Copy, Save & Pin

- Use the toolbar buttons to copy the current screenshot (with annotations) to the clipboard or save it as PNG.
- The "Set Hotkey…" window also provides a save-location setting. The default is the Downloads folder; you can choose another folder or restore the default. Screenshots, pinned images, and recordings share this location.
- Click the pin button to show the screenshot as a floating always-on-top image and finish the capture session. The floating image can be dragged; right-click to "Save" or "Destroy".

### Vertical & Horizontal Scrolling Capture

1. Select the scrollable content area.
2. Click the vertical or horizontal scrolling-capture button. During capture, the selection border stays visible and the target app still receives scroll input.
3. Scroll slowly inside the selection. SnapMark automatically detects the up/down or left/right direction and stitches frames by matching overlapping content; changing direction mid-scroll is also handled.
4. Press the screenshot hotkey again, or choose "Stop Scrolling Capture" from the menu bar, to finish. The result appears as a pinned preview you can save or destroy.

Scroll slowly and continuously, avoiding skipping large chunks of content. Blank, repetitive, or unreliable frames are conservatively skipped to reduce the risk of duplicated content; the canvas is capped at 24,000,000 pixels.

### Screen Recording

- Open the menu-bar SnapMark menu and choose "Record Current Screen" or "Select Region to Record…". After selecting a region (or confirming the full screen), a "Start Recording" button appears; recording only begins after you confirm. Press `Esc` or right-click to cancel.
- While recording, the captured region is outlined in red and the area outside is dimmed to show exactly what is being recorded; this overlay is excluded from the capture and does not appear in the output.
- Recordings are H.264-encoded MP4 with **no audio**, saved to the configured save location with a timestamped filename.
- The menu bar shows recording status, and the "Record Current Screen / Select Region to Record" items are greyed out during recording. Choose "Stop Recording" from the menu bar to finish. Recording is stopped automatically if the app quits.

## System Requirements

- macOS 14 or later
- Apple Silicon (current build target is `arm64`)

## Download

The latest version and all previous versions are published on GitHub Releases:

- Latest: https://github.com/BabyWords/SnapMark/releases/latest
- All releases: https://github.com/BabyWords/SnapMark/releases

## Automatic Updates

SnapMark supports automatic updates: the app periodically checks for new versions and prompts to download and install them automatically.

## Screen Recording Permission

Screenshots, scrolling capture, and recording all require the macOS Screen Recording permission. On first use, follow the prompt to "System Settings → Privacy & Security → Screen Recording" and grant access to SnapMark; you can also open the setting from the menu-bar permission item. Restart the app if prompted after the permission changes.

## Signing Risk

> ⚠️ This app is signed with a local self-signed certificate — it has **no Apple Developer ID certificate and has not been notarized by Apple**.

As a result, macOS Gatekeeper will flag it as an "unverified developer" or "unidentified developer". On each Mac, you need to allow it once:

1. Right-click the app → "Open" (instead of double-clicking), or click "Open Anyway" in "System Settings → Privacy & Security".
2. On the first screenshot/recording, enable SnapMark under "System Settings → Privacy & Security → Screen Recording".

After allowing it once, it runs normally and subsequent automatic updates no longer prompt. This approach is free and suitable for personal devices; to distribute publicly or fully eliminate Gatekeeper warnings, an Apple Developer account ($99/year) with Developer ID signing and notarization is required.

## Privacy

Screen capture and recording use the macOS screen-capture APIs; text recognition runs locally via Apple Vision. The project has no logic that uploads screenshots, recordings, or OCR content to any remote service.

## License

This repository currently ships without an open-source license. Being publicly visible does not grant others permission to copy, modify, or distribute the code; add an appropriate license file if you plan to open it up.
