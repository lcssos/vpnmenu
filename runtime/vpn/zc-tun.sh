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
# 隧道真正可用（utun 就绪、初始 /32 路由写好）后才写这个标记。
# App 和 zc-vpn-status 都以它为准，避免把“进程还在等 utun”误报成已连接。
READYFILE=/var/run/zju-connect.ready
# cleanup 完整跑完（含 DNS 还原）后写入，供 zc-vpn-off 判断是否需要再做一次兜底还原
CLEANFILE=/var/run/zju-connect.clean
# 本脚本自己接管系统 DNS 时，把设置的地址记下来，供 zc-dns-restore 识别是否仍是我们的值
ACTIVE_DNS_FILE=/var/run/zju-connect.dns.active

: "${VPN_SERVER:?缺少服务器地址}"
VPN_PORT="${VPN_PORT:-4430}"
VPN_IF="${VPN_IF:-utun4}"
SOCKS_BIND="${SOCKS_BIND:-127.0.0.1:1090}"
HTTP_BIND="${HTTP_BIND:-127.0.0.1:1091}"
# 两个功能的实现方（由配置里的 dnsMode / multiLine 决定，默认都走本脚本）
DNS_MODE="${VPN_DNS_MODE:-script}"
MULTI_LINE="${VPN_MULTI_LINE:-script}"

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
# 清掉上一次可能残留的就绪标记，等本次 utun / 路由真正就绪后再写
rm -f "$READYFILE" "$CLEANFILE" "$ACTIVE_DNS_FILE"
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

# zc-dns-restore 按这个快照还原系统 DNS。
#   DNS_MODE=zju：zju-connect 的 -dns-hijack 会改所有服务，必须在启动前全量快照；
#   DNS_MODE=script（默认）：apply_system_dns 只改有 IP 的服务，设置前逐个记录原值，
#   不再为闲置服务白等 networksetup（VPN 刚断开时每次调用可能慢到 1 秒）。
DNS_SNAPSHOT=/var/run/zju-connect.dns
if [[ "$DNS_MODE" == "zju" ]]; then
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
else
  rm -f "$DNS_SNAPSHOT"
fi

# 日志轮转：超过 5MB 时把上一份留成 .1，避免长期使用无限增长
if [[ -f "$LOG" ]]; then
  LOG_SIZE=$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)
  if (( LOG_SIZE > 5 * 1024 * 1024 )); then
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
  fi
fi

# 两个功能可以按配置选择实现方：
#   DNS_MODE=script   系统 DNS 由 apply_system_dns 只对活跃服务设置（默认）
#   DNS_MODE=zju      zju-connect 的 -dns-hijack 串行遍历所有服务（约多等 10 秒）
#   MULTI_LINE=script 不做 ping 测速，直接使用配置的 server（默认）
#   MULTI_LINE=zju    zju-connect 登录后自动 ping 各线路选最优（约多等 2 秒）
if [[ "$DNS_MODE" == "zju" ]]; then
  DNS_ARG="-dns-hijack"
else
  DNS_ARG="-dns-hijack=false"
fi
if [[ "$MULTI_LINE" == "zju" ]]; then
  MULTI_ARG=""
else
  MULTI_ARG="-disable-multi-line"
fi
echo "modes: dns=$DNS_MODE multi-line=$MULTI_LINE" >> "$LOG"

"$DIR/zju-connect" -server "$VPN_SERVER" -port "$VPN_PORT" -username "$VPN_ACCOUNT" \
  -disable-zju-config -remote-dns-server auto \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  -socks-bind "$SOCKS_BIND" -http-bind "$HTTP_BIND" \
  -tun-mode -add-route "$DNS_ARG" ${MULTI_ARG:+"$MULTI_ARG"} >> "$LOG" 2>&1 &
VPN_PID=$!

cleanup() {
  # 可能还有后台的 apply_system_dns 在改 DNS：先终止/等它结束，再按快照还原，
  # 避免还原之后它又把 DNS 改回 VPN 地址。
  if [[ -n "${DNS_APPLY_PID:-}" ]]; then
    /bin/kill "$DNS_APPLY_PID" 2>/dev/null
    wait "$DNS_APPLY_PID" 2>/dev/null
    DNS_APPLY_PID=""
  fi
  /bin/kill "$VPN_PID" 2>/dev/null
  wait "$VPN_PID" 2>/dev/null
  rm -f "$PIDFILE" "$READYFILE"
  # 系统 DNS 由本脚本设置，退出时统一按启动前快照还原
  /bin/bash "$DIR/zc-dns-restore" >/dev/null 2>&1 || true
  : > "$CLEANFILE" 2>/dev/null || true
  chmod 644 "$CLEANFILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT

# 等 utun 出现；期间如果 zju-connect 已经退出（如认证失败），立刻失败返回，
# 不要让包装脚本继续空等 40+20 秒、把状态误报成“连接中”。
UTUN_OK=no
for _ in $(seq 1 40); do
  if ifconfig "$VPN_IF" >/dev/null 2>&1; then UTUN_OK=yes; break; fi
  if ! /bin/kill -0 "$VPN_PID" 2>/dev/null; then
    echo "zju-connect exited before tun interface $VPN_IF appeared" >> "$LOG"
    exit 1
  fi
  sleep 1
done
if [[ "$UTUN_OK" != yes ]]; then
  echo "tun interface $VPN_IF did not appear within 40s" >> "$LOG"
  exit 1
fi

# 内网 DNS 就是隧道接口自己的地址；每个会话分配到的虚拟 IP 可能不同
# （见过 2.0.1.1 / 2.0.1.2），不能写死
VPN_DNS=$(ifconfig "$VPN_IF" 2>/dev/null | awk '/inet /{print $2}' | head -1)
[[ -z "$VPN_DNS" ]] && VPN_DNS="2.0.1.1"

# 等内网 DNS 可用（只在配置了域名路由时才有意义）
if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  for _ in $(seq 1 20); do
    dig @"$VPN_DNS" +time=2 +tries=1 +short "${DOMAINS[0]}" 2>/dev/null \
      | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && break
    if ! /bin/kill -0 "$VPN_PID" 2>/dev/null; then
      echo "zju-connect exited during DNS readiness wait" >> "$LOG"
      exit 1
    fi
    sleep 1
  done
fi

# 接管系统 DNS（替代 zju-connect -dns-hijack 的串行全量遍历）。
# 只改当前有 IPv4 地址的网络服务：闲置服务（未连接的 Thunderbolt Bridge、
# iPhone USB 等）不改，避免每个服务白等 networksetup 的 1-2 秒。
# 配置了域名路由时，上面的等待已经确认内网 DNS 可用，因此不会出现解析空窗。
apply_system_dns() {
  local svc cur list=""
  # 只快照本次真正会改的服务：先记录原值再设置，进程中途被强杀也能还原。
  : > "$DNS_SNAPSHOT" 2>/dev/null || true
  # 先把目标值记下来：即使设置到一半被强杀，zc-dns-restore 也能识别残留并还原。
  printf '%s\n' "$VPN_DNS" > "$ACTIVE_DNS_FILE" 2>/dev/null || true
  chmod 644 "$ACTIVE_DNS_FILE" 2>/dev/null || true
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    networksetup -getinfo "$svc" 2>/dev/null \
      | grep -qE '^IP address: [0-9]+\.' || continue
    cur=$(networksetup -getdnsservers "$svc" 2>/dev/null \
      | grep -E '^[0-9]+(\.[0-9]+){3}$' | tr '\n' ' ' | sed 's/ *$//')
    [[ "$cur" =~ 2\.0\.1\.[0-9]+ ]] && cur=""
    if ! printf '%s\t%s\n' "$svc" "$cur" >> "$DNS_SNAPSHOT" 2>/dev/null; then
      echo "failed to record DNS snapshot for $svc" >> "$LOG"
      continue
    fi
    if networksetup -setdnsservers "$svc" "$VPN_DNS" >/dev/null 2>&1; then
      list="$list $svc"
    else
      echo "failed to set DNS server on $svc" >> "$LOG"
    fi
  done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//')
  chmod 644 "$DNS_SNAPSHOT" 2>/dev/null || true

  [[ -z "$list" ]] && return 0
  echo "system DNS set to $VPN_DNS on:$list" >> "$LOG"
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
}

# 系统 DNS 与域名路由互不依赖（dig 直接指定内网 DNS），并行执行；
# 写就绪标记前再等 DNS 设置完成，避免“已连接但内网域名还解析不了”。
DNS_APPLY_PID=""
if [[ "$DNS_MODE" == "zju" ]]; then
  echo "system DNS left to zju-connect (-dns-hijack)" >> "$LOG"
else
  apply_system_dns &
  DNS_APPLY_PID=$!
fi

resolve_domain() {
  local d="$1" ips
  # 两次足够覆盖偶发失败；无 A 记录的域名不再白等 3×2s。
  # 仍未解析出来的域名由 5 分钟一次的后台刷新兜底。
  for _ in 1 2; do
    ips=$(dig @"$VPN_DNS" +time=2 +tries=1 +short "$d" 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [[ -n "$ips" ]] && { printf '%s\n' "$ips"; return 0; }
    sleep 0.3
  done
  return 0
}

add_domain_routes() {
  [[ ${#DOMAINS[@]} -eq 0 ]] && return 0
  local d ip i p
  local -a pids=()
  local tmp
  if ! tmp=$(mktemp -d "${TMPDIR:-/tmp}/vpnmenu-routes.XXXXXX"); then
    # 拿不到临时目录时退回串行，功能不受影响
    for d in "${DOMAINS[@]}"; do
      for ip in $(resolve_domain "$d"); do
        route -n add -host "$ip" -interface "$VPN_IF" >/dev/null 2>&1 || true
      done
    done
    return 0
  fi

  # 并发解析：慢域名（内网 DNS 要等 10+ 秒）不再串行拖累后续域名。
  # 每个子进程把解析结果写到独立文件，最后统一加路由。
  i=0
  for d in "${DOMAINS[@]}"; do
    ( resolve_domain "$d" ) > "$tmp/$i" 2>/dev/null &
    pids+=($!)
    i=$((i + 1))
  done
  # 只等这些解析子进程，不能裸 wait——zju-connect 也是本脚本的子进程，会永远等下去。
  for p in "${pids[@]}"; do wait "$p"; done

  i=0
  for d in "${DOMAINS[@]}"; do
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      route -n add -host "$ip" -interface "$VPN_IF" >/dev/null 2>&1 || true
    done < "$tmp/$i"
    i=$((i + 1))
  done
  rm -rf "$tmp"
}

add_domain_routes

# 系统 DNS 设置完成后再写就绪标记（它与域名路由是并行跑的）
if [[ -n "$DNS_APPLY_PID" ]]; then
  wait "$DNS_APPLY_PID" 2>/dev/null
  DNS_APPLY_PID=""
fi

# 到这里才认为隧道可用：写入就绪标记（包装脚本 PID + zju-connect PID）
if ! /bin/kill -0 "$VPN_PID" 2>/dev/null; then
  echo "zju-connect exited before ready marker" >> "$LOG"
  exit 1
fi
printf '%s %s\n' "$$" "$VPN_PID" > "$READYFILE"
chmod 644 "$READYFILE" 2>/dev/null || true

# 每 5 分钟刷新一次，应对 DNS 轮换 / 路由失效；同时每 5 秒确认 zju-connect 还活着。
# 不用后台刷新子进程：那样父脚本被 kill -9 时会留下孤儿，TERM 也可能被 sleep 推迟。
while /bin/kill -0 "$VPN_PID" 2>/dev/null; do
  for _ in $(seq 1 60); do
    /bin/kill -0 "$VPN_PID" 2>/dev/null || break 2
    # 用「后台 sleep + wait」而不是前台 sleep：让 TERM/INT 能立刻打断等待，
    # 点「断开」不用等满 5 秒才执行 cleanup trap。
    sleep 5 & wait $!
  done
  add_domain_routes
done
