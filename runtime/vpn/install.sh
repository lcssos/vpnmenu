#!/bin/bash
# 一次性安装（需要 root；App 会在首次连接时用「管理员密码」弹窗调用）
# 用法: install.sh <vpn目录> <用户名>
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPN_DIR="${1:-$DIR}"
TARGET_USER="${2:-${SUDO_USER:-}}"

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "用法: install.sh <vpn目录> <用户名>" >&2
  exit 1
fi

# sudoers 的路径匹配不处理空格，路径里有空格会装不上
case "$VPN_DIR" in
  *" "*) echo "错误：App 路径包含空格，请把 VPNMenu.app 放到 /Applications 下" >&2; exit 1 ;;
esac

# 1) 先停掉正在运行的实例（含旧位置）
"$VPN_DIR/zc-vpn-off" >/dev/null 2>&1 || true
pkill -f '/usr/local/libexec/zju-connect/' 2>/dev/null || true
rm -f /var/run/zju-connect.pid

# 2) 清理旧版散落在系统里的组件
rm -f  /etc/sudoers.d/zc-vpn
rm -rf /usr/local/libexec/zju-connect
rm -f  /usr/local/bin/zc-vpn-on /usr/local/bin/zc-vpn-off /usr/local/bin/zc-vpn-status

# 3) 整个 App 归 root:wheel，普通用户不可改
#    （否则用户可替换 Resources/vpn 目录，让 sudoers 放行的路径指向恶意脚本）
APP_ROOT="$(cd "$VPN_DIR/../../.." && pwd)"
chown -R root:wheel "$APP_ROOT"
chmod 755 "$APP_ROOT" "$APP_ROOT/Contents" "$APP_ROOT/Contents/Resources" "$VPN_DIR"
chmod 755 "$VPN_DIR/zju-connect" \
          "$VPN_DIR/zc-tun.sh" \
          "$VPN_DIR/zc-vpn-on" \
          "$VPN_DIR/zc-vpn-off" \
          "$VPN_DIR/zc-vpn-status" \
          "$VPN_DIR/install.sh" \
          "$VPN_DIR/uninstall.sh" 2>/dev/null || true
chmod 644 "$VPN_DIR/README.md" 2>/dev/null || true
# 凭据已改存 macOS 登录钥匙串；清理旧版明文密码文件
rm -f "$VPN_DIR/.pw"
# 旧版把服务器/域名写在包内 vpn.conf；现在配置在本机 Application Support，包里不再有
rm -f "$VPN_DIR/vpn.conf"
find "$VPN_DIR" -type f -perm -g+w -exec chmod g-w {} + 2>/dev/null || true
find "$VPN_DIR" -type f -perm -o+w -exec chmod o-w {} + 2>/dev/null || true

# 4) sudoers：只放行这一个 App 内的启停脚本
ON="$VPN_DIR/zc-vpn-on"
OFF="$VPN_DIR/zc-vpn-off"
TMP="$(mktemp /tmp/vpnmenu-sudo.XXXXXX)"
cat > "$TMP" <<SUDO
$TARGET_USER ALL=(root) NOPASSWD: $ON, $OFF
SUDO
chown root:wheel "$TMP"
chmod 440 "$TMP"
visudo -cf "$TMP" >/dev/null
mv "$TMP" /etc/sudoers.d/vpnmenu
chown root:wheel /etc/sudoers.d/vpnmenu
chmod 440 /etc/sudoers.d/vpnmenu

echo INSTALL_OK
