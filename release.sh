#!/bin/bash
# SnapMark 发版脚本：构建 → 打包 zip → 生成 appcast → 上传 GitHub Release。
#
# 用法:
#   ./release.sh 1.1.0 "本次更新的说明"
#
# 前置条件:
#   1. 已在本机生成过 Sparkle 签名密钥（私钥在钥匙串里）——首次发版前运行过一次
#      ./Vendor/tools/generate_keys 即可。
#   2. 已安装并登录 gh CLI（github.com 认证，账号需有该仓库写权限）。
#
# 说明:
#   - 更新源 URL 在 Info.plist 的 SUFeedURL，指向
#     https://github.com/BabyWords/SnapMark/releases/latest/download/appcast.xml
#   - 脚本会把新版本号写入 Info.plist 并提交，再构建、打包、上传。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?用法: ./release.sh <版本号> [发布说明]}"
NOTES="${2:-}"

# 去掉可能误写的 v 前缀
VERSION="${VERSION#v}"
REPO="BabyWords/SnapMark"
TAG="v$VERSION"
ZIP_NAME="SnapMark-$VERSION.zip"
DIST_DIR="dist"

command -v gh >/dev/null 2>&1 || { echo "错误: 未安装 gh CLI。请先 brew install gh 并 gh auth login"; exit 1; }

echo "==> 更新版本号为 $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist

echo "==> 构建"
./build.sh

echo "==> 打包 $ZIP_NAME"
mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/*.zip "$DIST_DIR"/appcast.xml
ditto -c -k --keepParent "build/SnapMark.app" "$DIST_DIR/$ZIP_NAME"

echo "==> 生成 appcast"
./Vendor/tools/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  "$DIST_DIR"

echo "==> 上传 GitHub Release $TAG"
gh release create "$TAG" \
  "$DIST_DIR/$ZIP_NAME" \
  "$DIST_DIR/appcast.xml" \
  --repo "$REPO" \
  --title "SnapMark $VERSION" \
  --notes "${NOTES:-SnapMark $VERSION}"

echo "==> 提交版本号更新"
git add Info.plist
git commit -m "Bump version to $VERSION" || echo "(无版本号变更，跳过提交)"

echo "==> 完成。其他 Mac 上打开 SnapMark 后会自动检查到 $VERSION 更新。"
