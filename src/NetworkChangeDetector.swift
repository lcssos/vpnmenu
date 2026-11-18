// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// 网络变化判定（纯逻辑，便于单元测试）。
///
/// - 第一次看到可用的网络签名只作为基线，不触发事件；
/// - 签名变化后要稳定 `settle` 秒才触发，避开 DHCP / 链路切换过程中的中间态；
/// - 先断网（unsatisfied）再恢复，即使签名和之前相同也算一次变化——同一条 Wi-Fi
///   重新连上时 IP 可能不变，但底层 TCP 连接已经断了。
struct NetworkChangeDetector {
    let settle: TimeInterval

    private(set) var stableSignature: String?
    private var candidate: String?
    private var candidateSince: Date?
    private var wasUnsatisfied = false

    init(settle: TimeInterval = 3.0) {
        self.settle = settle
    }

    /// 是否有一个还没稳定的候选签名（调用方据此安排一次延时复检）。
    var hasPending: Bool { candidate != nil }

    /// 喂入当前签名与链路状态；返回 true 表示网络确实发生了变化且已经稳定。
    mutating func update(signature: String, satisfied: Bool, now: Date = Date()) -> Bool {
        guard satisfied, !signature.isEmpty else {
            wasUnsatisfied = true
            candidate = nil
            candidateSince = nil
            return false
        }

        guard let stable = stableSignature else {
            // 启动时（或刚从离线恢复时）的第一份可用签名只做基线
            stableSignature = signature
            candidate = nil
            candidateSince = nil
            wasUnsatisfied = false
            return false
        }

        if signature != candidate {
            candidate = signature
            candidateSince = now
            return false
        }

        guard let since = candidateSince, now.timeIntervalSince(since) >= settle else {
            return false
        }

        candidate = nil
        candidateSince = nil
        guard signature != stable || wasUnsatisfied else { return false }

        stableSignature = signature
        wasUnsatisfied = false
        return true
    }
}
