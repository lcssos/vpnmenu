#!/bin/bash
# Copyright (C) 2026 lcssos
# SPDX-License-Identifier: AGPL-3.0-only
# 以 root 运行：启动 zju-connect TUN 模式、等待隧道就绪、注入域名路由
#
# 连接参数全部来自环境变量（由 zc-vpn-on 解析 App 的 stdin 后传入）。
# 本脚本不读取、也不执行任何配置文件。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE=/var/run/zju-connect.pid

: "${VPN_SERVER:?缺少服务器地址}"
VPN_PORT="${VPN_PORT:-4430}"
VPN_IF="${VPN_IF:-utun4}"
SOCKS_BIND="${SOCKS_BIND:-127.0.0.1:1090}"
HTTP_BIND="${HTTP_BIND:-127.0.0.1:1091}"

DOMAINS=()
PROXY_DOMAINS=()
if [[ -n "${VPN_DOMAINS:-}" ]]; then
  read -r -a DOMAINS <<< "$VPN_DOMAINS"
fi
if [[ -n "${VPN_PROXY_DOMAINS:-}" ]]; then
  read -r -a PROXY_DOMAINS <<< "$VPN_PROXY_DOMAINS"
fi

# 日志写到当前登录用户的 ~/Library/Logs/VPNMenu/
LOGUSER="${SUDO_USER:-$(/usr/bin/stat -f%Su /dev/console)}"
LOGDIR="$(eval echo "~$LOGUSER")/Library/Logs/VPNMenu"
mkdir -p "$LOGDIR" || exit 1
[[ "$(id -u)" == "0" && "$LOGUSER" != "root" ]] && chown "$LOGUSER" "$LOGDIR" 2>/dev/null
LOG="$LOGDIR/zju-connect.log"

# 单实例：已在跑就直接退出
if [[ -f "$PIDFILE" ]] && /bin/kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  exit 0
fi
echo "$$" > "$PIDFILE"

# 账号/密码由 zc-vpn-on 从 App 的 stdin 读入后通过环境变量传入，不落盘。
# 注意：只有 ZJU_CONNECT_PASSWORD 是 zju-connect 认识的键；用户名走 -username 参数，
# 否则它会把未知的 ZJU_CONNECT_* 当成非法配置直接退出。
: "${VPN_ACCOUNT:?缺少用户名——请在菜单栏「设置账号…」中录入}"
: "${VPN_SECRET:?缺少密码——请在菜单栏「设置账号…」中录入}"

export ZJU_CONNECT_PASSWORD="$VPN_SECRET"

cd "$DIR" || exit 1

EXTRA=()
if [[ ${#PROXY_DOMAINS[@]} -gt 0 ]]; then
  for d in "${PROXY_DOMAINS[@]}"; do
    EXTRA+=(-custom-proxy-domain "$d")
  done
fi

# -dns-hijack 会把各网络服务的 DNS 改成 VPN 内网地址，而 zju-connect 在 panic 时
# 不会执行自己的清理。启动前先记下原始 DNS，异常退出后由 zc-dns-restore 按快照还原。
DNS_SNAPSHOT=/var/run/zju-connect.dns
: > "$DNS_SNAPSHOT" 2>/dev/null || true
while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  cur=$(networksetup -getdnsservers "$svc" 2>/dev/null \
    | grep -E '^[0-9]+(\.[0-9]+){3}$' | tr '\n' ' ' | sed 's/ *$//')
  # 上一次崩溃可能留下 2.0.1.x，这种“原值”等同于自动获取
  [[ "$cur" =~ 2\.0\.1\.[0-9]+ ]] && cur=""
  printf '%s\t%s\n' "$svc" "$cur" >> "$DNS_SNAPSHOT"
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//')
chmod 644 "$DNS_SNAPSHOT" 2>/dev/null || true

"$DIR/zju-connect" -server "$VPN_SERVER" -port "$VPN_PORT" -username "$VPN_ACCOUNT" \
  -disable-zju-config -remote-dns-server auto \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  -socks-bind "$SOCKS_BIND" -http-bind "$HTTP_BIND" \
  -tun-mode -add-route -dns-hijack >> "$LOG" 2>&1 &
VPN_PID=$!

cleanup() {
  /bin/kill "$VPN_PID" 2>/dev/null
  wait "$VPN_PID" 2>/dev/null
  rm -f "$PIDFILE"
  # 正常退出时 zju-connect 已自己清过 DNS，这一步是 panic/强杀时的兜底
  /bin/bash "$DIR/zc-dns-restore" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT

# 等 utun 出现
for _ in $(seq 1 40); do
  ifconfig "$VPN_IF" >/dev/null 2>&1 && break
  sleep 1
done

# 内网 DNS 就是隧道接口自己的地址；每个会话分配到的虚拟 IP 可能不同
# （见过 2.0.1.1 / 2.0.1.2），不能写死
VPN_DNS=$(ifconfig "$VPN_IF" 2>/dev/null | awk '/inet /{print $2}' | head -1)
[[ -z "$VPN_DNS" ]] && VPN_DNS="2.0.1.1"

# 等内网 DNS 可用（只在配置了域名路由时才有意义）
if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  for _ in $(seq 1 20); do
    dig @"$VPN_DNS" +time=2 +tries=1 +short "${DOMAINS[0]}" 2>/dev/null \
      | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && break
    sleep 1
  done
fi

add_domain_routes() {
  [[ ${#DOMAINS[@]} -eq 0 ]] && return 0
  local d ips ip
  for d in "${DOMAINS[@]}"; do
    ips=""
    for _ in 1 2 3; do
      ips=$(dig @"$VPN_DNS" +time=2 +tries=1 +short "$d" 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
      [[ -n "$ips" ]] && break
      sleep 1
    done
    for ip in $ips; do
      route -n add -host "$ip" -interface "$VPN_IF" >/dev/null 2>&1 || true
    done
  done
}

add_domain_routes

# 每 5 分钟刷新一次，应对 DNS 轮换 / 路由失效；同时每 5 秒确认 zju-connect 还活着。
# 不用后台刷新子进程：那样父脚本被 kill -9 时会留下孤儿，TERM 也可能被 sleep 推迟。
while /bin/kill -0 "$VPN_PID" 2>/dev/null; do
  for _ in $(seq 1 60); do
    /bin/kill -0 "$VPN_PID" 2>/dev/null || break 2
    sleep 5
  done
  add_domain_routes
done
