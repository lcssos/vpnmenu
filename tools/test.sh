#!/bin/bash
# Copyright (C) 2026 lcssos
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 -o "$ROOT/build/vpnmenu-tests" \
  "$ROOT"/tests/*.swift \
  "$ROOT"/src/Backends/*.swift \
  "$ROOT"/src/Profile.swift \
  "$ROOT"/src/Process.swift
"$ROOT/build/vpnmenu-tests"
