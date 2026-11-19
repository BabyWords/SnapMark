#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SnapMark"
APP="build/$APP_NAME.app"
DMG="build/$APP_NAME.dmg"
STAGING="build/dmg-staging"

if [ ! -d "$APP" ]; then
  printf '未找到 %s，请先执行：bash build.sh\n' "$APP" >&2
  exit 1
fi

printf '==> 打包 %s 为 DMG\n' "$APP_NAME"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"

cp -R "$APP" "$STAGING/"
# 拖拽安装用的 Applications 快捷方式
ln -s /Applications "$STAGING/Applications"

# UDZO 为压缩格式，体积更小；UDRO 为未压缩只读（体积大但挂载快）。
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGING"

printf '==> 已生成 %s\n' "$DMG"
