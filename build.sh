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
  -framework ImageIO \
  -framework Vision \
  Sources/*.swift \
  -o "$EXECUTABLE"

cp Info.plist "$APP/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signing avoids requiring any developer-specific certificate or secret.
codesign --force --sign - "$APP"

printf '==> Built %s\n' "$APP"
printf 'Open it with: open "%s"\n' "$APP"
