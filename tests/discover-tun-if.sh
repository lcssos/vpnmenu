#!/bin/bash
# Copyright (C) 2026 lcssos
# SPDX-License-Identifier: AGPL-3.0-only
# zc-tun.sh 必须从本次启动之后的日志里认出 zju-connect 实际创建的 utun，
# 不能把更早会话的 Interface Name 或配置里写死的名字当成当前网卡。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/runtime/vpn/zc-tun.sh"
TMP="$(mktemp)"
fail=0

check() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name (got $(printf %q "$got"), want $(printf %q "$want"))"
    fail=1
  fi
}

cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

printf '2026/11/22 18:06:33 Interface Name: utun7, index 18\n' > "$TMP"
got="$("$SCRIPT" --discover-tun-if "$TMP" 1)"
check "$got" "utun7" "reads the interface zju-connect created"

printf '2026/11/22 17:21:08 Interface Name: utun4, index 15\n' > "$TMP"
off=$(( $(stat -f%z "$TMP") + 1 ))
printf '2026/11/22 18:06:33 Interface Name: utun7, index 18\n' >> "$TMP"
got="$("$SCRIPT" --discover-tun-if "$TMP" "$off")"
check "$got" "utun7" "ignores interface names from earlier sessions"

printf 'Interface Name: utun4, index 15\nInterface Name: utun7, index 18\n' > "$TMP"
got="$("$SCRIPT" --discover-tun-if "$TMP" 1)"
check "$got" "utun7" "keeps the latest interface name in this session"

printf 'VPN client started\n' > "$TMP"
if "$SCRIPT" --discover-tun-if "$TMP" 1 >/dev/null; then
  echo "FAIL missing interface name should fail"
  fail=1
else
  echo "ok   missing interface name fails"
fi

printf 'Interface Name: en0, index 1\n' > "$TMP"
if "$SCRIPT" --discover-tun-if "$TMP" 1 >/dev/null; then
  echo "FAIL non-utun name should fail"
  fail=1
else
  echo "ok   non-utun name is ignored"
fi

printf 'Interface Name: utun1234, index 20\n' > "$TMP"
if "$SCRIPT" --discover-tun-if "$TMP" 1 >/dev/null; then
  echo "FAIL four-digit utun should fail"
  fail=1
else
  echo "ok   four-digit utun name is ignored"
fi

exit "$fail"
