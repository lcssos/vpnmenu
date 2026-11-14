#!/bin/bash
# Copyright (C) 2026 lcssos
# SPDX-License-Identifier: AGPL-3.0-only
# 卸载：停止 VPN、撤销 sudoers 免密规则、移除登录自启（App 本身请手动拖到废纸篓）
set -uo pipefail

# 删 sudoers、杀 root 进程都需要 root；从普通用户运行时就地提权。
if [[ $EUID -ne 0 ]]; then
  exec /usr/bin/sudo "$0" "$@"
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 登录自启属于「当前登录用户」，不是 root：优先用 sudo 的原用户
TARGET_USER="${SUDO_USER:-$(/usr/bin/stat -f%Su /dev/console)}"
TARGET_UID="$(/usr/bin/id -u "$TARGET_USER" 2>/dev/null || true)"
TARGET_HOME="$(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null \
  | /usr/bin/awk '{print $2}')"

"$DIR/zc-vpn-off" >/dev/null 2>&1 || true
rm -f /etc/sudoers.d/vpnmenu
rm -f /var/run/zju-connect.pid /var/run/zju-connect.ready

# 停掉并删除 LaunchAgent，避免 App 删除后每次登录都尝试启动一个不存在的路径
if [[ -n "$TARGET_UID" ]]; then
  /bin/launchctl bootout "gui/$TARGET_UID/com.lcssos.vpnmenu" 2>/dev/null || true
fi
if [[ -n "$TARGET_HOME" ]]; then
  rm -f "$TARGET_HOME/Library/LaunchAgents/com.lcssos.vpnmenu.plist"
fi

echo "已停止 VPN、移除免密规则和登录自启。现在可以把 VPNMenu.app 删除。"
echo "日志保留在 ~/Library/Logs/VPNMenu/（可手动删除）。"
