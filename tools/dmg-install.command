#!/bin/bash
# Copyright (C) 2026 lcssos
# SPDX-License-Identifier: AGPL-3.0-only
# 从 DMG 安装 / 升级 VPNMenu。
#
# 安装后 App 会被 install.sh 改成 root:wheel（sudoers 只放行 App 内的启停脚本，
# 必须防止普通用户替换它们），所以 Finder 无法用当前用户覆盖旧版本。
# 本脚本负责：退出旧实例 → 用管理员权限删除并复制 App → 重跑安装脚本 → 启动。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/VPNMenu.app"
DST="/Applications/VPNMenu.app"

pause() {
  read -r -p "按回车关闭窗口…" _ || true
}

if [[ ! -x "$SRC/Contents/MacOS/VPNMenu" ]]; then
  echo "错误：没有找到 VPNMenu.app。请从 VPNMenu DMG 的窗口里运行本脚本。" >&2
  pause
  exit 1
fi

echo "== 退出正在运行的 VPNMenu"
osascript -e 'tell application id "com.lcssos.vpnmenu" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  pgrep -f "$DST/Contents/MacOS/VPNMenu" >/dev/null 2>&1 || break
  sleep 0.5
done
pkill -f "$DST/Contents/MacOS/VPNMenu" 2>/dev/null || true
sleep 0.5

echo "== 安装到 $DST（需要管理员密码）"
if ! sudo /bin/rm -rf "$DST"; then
  echo "错误：无法删除旧版本。" >&2
  pause
  exit 1
fi
if ! sudo /usr/bin/ditto "$SRC" "$DST"; then
  echo "错误：复制 App 失败。" >&2
  pause
  exit 1
fi
if ! sudo /bin/bash "$DST/Contents/Resources/vpn/install.sh" \
       "$DST/Contents/Resources/vpn" "$(id -un)"; then
  echo "错误：安装脚本执行失败。" >&2
  pause
  exit 1
fi

echo "== 启动 VPNMenu"
open "$DST"
echo "完成。首次连接会要求输入一次管理员密码，之后在菜单栏点「连接」即可。"
pause
