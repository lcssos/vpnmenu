#!/bin/bash
# Copyright (C) 2026 lcssos
# SPDX-License-Identifier: AGPL-3.0-only
# 从源码组装通用（x86_64 + arm64）VPNMenu.app
#
# 源码分布：
#   src/main.swift + src/Info.plist   App 本体
#   runtime/vpn/                      运行期脚本与配置（zc-*.sh、vpn.conf、install.sh）
#   vendor/zju-connect-darwin-*       两种架构的 zju-connect（可由 GitHub release 重新获取）
#   assets/                           图标产物（缺失时会自动生成）
# 产物：
#   package/VPNMenu.app               可直接分发/安装的 App
#   dist/VPNMenu.zip                  加 --dist 时额外打包的分发压缩包
#
# 用法：
#   tools/build.sh          只组装 App
#   tools/build.sh --dist   组装 App 并打包 dist/VPNMenu.zip
set -euo pipefail

DO_DIST=no
for arg in "$@"; do
  case "$arg" in
    --dist) DO_DIST=yes ;;
    -h|--help)
      sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "未知参数: ${arg}（可用: --dist）" >&2
      exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/package/VPNMenu.app"
BUILD="$ROOT/build"
RUNTIME="$ROOT/runtime/vpn"
VENDOR="$ROOT/vendor"
ASSETS="$ROOT/assets"

mkdir -p "$BUILD" "$ASSETS"

# ---------- 图标（缺失时生成） ----------
if [[ ! -f "$ASSETS/VPNMenu.icns" ]]; then
  echo "== 生成图标"
  [[ -x "$BUILD/make-icon" ]] || \
    swiftc -O -swift-version 5 -framework Cocoa -o "$BUILD/make-icon" "$ROOT/tools/make-icon.swift"
  "$BUILD/make-icon" "$ASSETS/icon-1024.png"
  rm -rf "$ASSETS/VPNMenu.iconset" && mkdir -p "$ASSETS/VPNMenu.iconset"
  for s in 16 32 64 128 256 512; do
    sips -z "$s" "$s" "$ASSETS/icon-1024.png" \
      --out "$ASSETS/VPNMenu.iconset/icon_${s}x${s}.png" >/dev/null
  done
  sips -z 1024 1024 "$ASSETS/icon-1024.png" \
    --out "$ASSETS/VPNMenu.iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ASSETS/VPNMenu.iconset" -o "$ASSETS/VPNMenu.icns"
fi

# ---------- App 本体 ----------
echo "== 编译 x86_64"
swiftc -O -swift-version 5 -target x86_64-apple-macos11.0 \
  -framework Cocoa -framework Security -o "$BUILD/VPNMenu-x86_64" "$ROOT/src/main.swift"

echo "== 编译 arm64"
swiftc -O -swift-version 5 -target arm64-apple-macos11.0 \
  -framework Cocoa -framework Security -o "$BUILD/VPNMenu-arm64" "$ROOT/src/main.swift"

lipo -create "$BUILD/VPNMenu-x86_64" "$BUILD/VPNMenu-arm64" -output "$BUILD/VPNMenu"

# ---------- 组装 bundle ----------
echo "== 组装 $PKG"
rm -rf "$PKG"
mkdir -p "$PKG/Contents/MacOS" "$PKG/Contents/Resources"
cp "$ROOT/src/Info.plist"            "$PKG/Contents/Info.plist"
cp "$ASSETS/VPNMenu.icns"            "$PKG/Contents/Resources/VPNMenu.icns"
cp "$BUILD/VPNMenu"                  "$PKG/Contents/MacOS/VPNMenu"
cp -R "$RUNTIME"                     "$PKG/Contents/Resources/vpn"

# 许可证与第三方声明要随 App 一起分发（zju-connect 是 AGPL-3.0）
cp "$ROOT/LICENSE"                   "$PKG/Contents/Resources/LICENSE"
cp "$ROOT/THIRD-PARTY-NOTICES.md"    "$PKG/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp -R "$ROOT/licenses"               "$PKG/Contents/Resources/licenses"

# ---------- zju-connect（两种架构合成通用） ----------
if [[ -f "$VENDOR/zju-connect-darwin-amd64" && -f "$VENDOR/zju-connect-darwin-arm64" ]]; then
  lipo -create "$VENDOR/zju-connect-darwin-amd64" "$VENDOR/zju-connect-darwin-arm64" \
    -output "$PKG/Contents/Resources/vpn/zju-connect"
else
  echo "缺少 vendor/zju-connect-darwin-{amd64,arm64}" >&2
  echo "从 https://github.com/Mythologyli/zju-connect/releases 下载后解压放进去" >&2
  exit 1
fi
chmod 755 "$PKG/Contents/MacOS/VPNMenu" \
          "$PKG/Contents/Resources/vpn/zju-connect" \
          "$PKG/Contents/Resources/vpn/install.sh" \
          "$PKG/Contents/Resources/vpn/uninstall.sh" \
          "$PKG/Contents/Resources/vpn/zc-tun.sh" \
          "$PKG/Contents/Resources/vpn/zc-vpn-on" \
          "$PKG/Contents/Resources/vpn/zc-vpn-off" \
          "$PKG/Contents/Resources/vpn/zc-vpn-status" \
          "$PKG/Contents/Resources/vpn/zc-dns-restore"
chmod 644 "$PKG/Contents/Info.plist" \
          "$PKG/Contents/Resources/VPNMenu.icns" \
          "$PKG/Contents/Resources/vpn/README.md" \
          "$PKG/Contents/Resources/LICENSE" \
          "$PKG/Contents/Resources/THIRD-PARTY-NOTICES.md" \
          "$PKG/Contents/Resources/licenses/AGPL-3.0.txt"

# ---------- 签名 ----------
echo "== 签名"
codesign --force --sign - --timestamp=none "$PKG/Contents/Resources/vpn/zju-connect"
codesign --force --sign - --timestamp=none "$PKG"
codesign --verify --deep --strict "$PKG" && echo "signature ok"

echo "== 架构"
lipo -archs "$PKG/Contents/MacOS/VPNMenu"
lipo -archs "$PKG/Contents/Resources/vpn/zju-connect"

# ---------- 分发压缩包 ----------
if [[ "$DO_DIST" == "yes" ]]; then
  DIST="$ROOT/dist"
  ZIP="$DIST/VPNMenu.zip"
  echo "== 打包 $ZIP"
  mkdir -p "$DIST"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$PKG" "$ZIP"
  ls -lh "$ZIP"
fi

echo "== 完成: $PKG"
