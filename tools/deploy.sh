#!/bin/bash
# Copyright (C) 2026 lcssos
# SPDX-License-Identifier: AGPL-3.0-only
# 把 package/VPNMenu.app 部署到 /Applications
#
# 用法:
#   tools/deploy.sh          只部署现有产物
#   tools/deploy.sh --build  先构建再部署
#
# 会弹一次系统管理员密码：覆盖 /Applications/VPNMenu.app、
# 重跑 install.sh（chown root、写 sudoers）、重启菜单栏进程；
# 如果部署前 VPN 是连接状态，部署后自动用钥匙串凭据恢复连接。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/package/VPNMenu.app"
DST="/Applications/VPNMenu.app"
VPN="$DST/Contents/Resources/vpn"
LABEL="com.lcssos.vpnmenu"
USER_NAME="$(id -un)"
UID_NUM="$(id -u)"

if [[ "${1:-}" == "--build" || "${1:-}" == "-b" ]]; then
  "$ROOT/tools/build.sh" || exit 1
fi

if [[ ! -d "$PKG" ]]; then
  echo "没有找到 ${PKG}；先运行 tools/build.sh，或用 tools/deploy.sh --build" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$PKG" >/dev/null 2>&1; then
  # .pw 之类 root-only 文件会让普通用户校验失败；这里只做尽力检查
  echo "提示：package 的严格签名校验未通过（若 .pw 尚存且为 600 属正常）" >&2
fi

# 记录部署前状态
WAS_CONNECTED=no
if [[ -x "$VPN/zc-vpn-status" ]] && "$VPN/zc-vpn-status" >/dev/null 2>&1; then
  WAS_CONNECTED=yes
fi

echo "== 安装到 ${DST}（需要管理员密码）"
if ! osascript -e "do shell script \"/bin/rm -rf \" & quoted form of \"$DST\" & \" && /usr/bin/ditto \" & quoted form of \"$PKG\" & \" \" & quoted form of \"$DST\" & \" && /bin/bash \" & quoted form of \"$DST/Contents/Resources/vpn/install.sh\" & \" \" & quoted form of \"$DST/Contents/Resources/vpn\" & \" \" & quoted form of \"$USER_NAME\" with administrator privileges"; then
  echo "（osascript 返回非零，以下方实际检查结果为准）" >&2
fi

if [[ ! -x "$VPN/zc-vpn-on" ]]; then
  echo "部署失败：$VPN 不完整" >&2
  exit 1
fi
if [[ ! -f /etc/sudoers.d/vpnmenu ]]; then
  echo "部署失败：sudoers 规则没有写入" >&2
  exit 1
fi

echo "== 重启菜单栏进程"
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$UID_NUM/$LABEL"
else
  open -a "$DST"
fi
sleep 2

if [[ "$WAS_CONNECTED" == "yes" ]]; then
  echo "== 恢复 VPN 连接"
  "$DST/Contents/MacOS/VPNMenu" --vpn-on >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    "$VPN/zc-vpn-status" >/dev/null 2>&1 && break
    sleep 1
  done
fi

echo "== 校验"
echo -n "App 架构:      "; lipo -archs "$DST/Contents/MacOS/VPNMenu"
echo -n "客户端架构:    "; lipo -archs "$VPN/zju-connect"
echo -n "菜单栏进程:    "; pgrep -fl "$DST/Contents/MacOS/VPNMenu" || echo "未运行"
echo -n "VPN 状态:      "; "$VPN/zc-vpn-status" || true

echo "== 完成"
