#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SnapMark"
APP="build/$APP_NAME.app"
EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"

mkdir -p "$(dirname "$EXECUTABLE")"

printf '==> Compiling %s\n' "$APP_NAME"
swiftc -swift-version 5 -O \
  -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework Carbon \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework ImageIO \
  -framework Vision \
  Sources/*.swift \
  -o "$EXECUTABLE"

cp Info.plist "$APP/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# 优先使用本地稳定的自签名证书签名。ad-hoc 签名会让 macOS 按代码哈希识别应用，
# 每次代码更新都会重新要求屏幕录制授权；用固定证书签名后，身份稳定，只需授权一次。
# 没有证书时回退到 ad-hoc（仍可运行，但更新后可能需要重新授权）。
SIGN_IDENTITY="SnapMark Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

printf '==> Built %s\n' "$APP"
printf 'Open it with: open "%s"\n' "$APP"
