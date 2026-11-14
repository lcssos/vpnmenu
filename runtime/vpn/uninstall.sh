#!/bin/bash
# Copyright (C) 2026 lcssos
# SPDX-License-Identifier: AGPL-3.0-only
# 卸载：停止 VPN、撤销 sudoers 免密规则（App 本身请手动拖到废纸篓）
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$DIR/zc-vpn-off" >/dev/null 2>&1 || true
rm -f /etc/sudoers.d/vpnmenu
rm -f /var/run/zju-connect.pid

echo "已移除 sudoers 规则并停止 VPN。现在可以把 VPNMenu.app 删除。"
echo "日志保留在 ~/Library/Logs/VPNMenu/（可手动删除）。"
