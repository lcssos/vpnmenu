// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

// MARK: - 网络切换后的自动重连

extension AppDelegate {
    /// 记录「我们主动连上/应该保持」的配置。只有它非空时才允许自动重连，
    /// 用户手动断开后会被清空。
    func armDesiredProfile(_ sel: (id: String, profile: Profile)) {
        desiredProfileID = sel.id
        desiredProfile = sel.profile
    }

    func clearDesiredProfile() {
        desiredProfileID = nil
        desiredProfile = nil
        pendingNetworkReconnect = false
    }

    /// 优先使用磁盘上的最新配置；配置被删掉时退回连接时的快照。
    func desiredSelection() -> (id: String, profile: Profile)? {
        guard let id = desiredProfileID else { return nil }
        if let hit = profiles.first(where: { $0.id == id }) { return hit }
        if let profile = desiredProfile { return (id, profile) }
        return nil
    }

    /// 统一入口：网络变化、隧道进程意外退出都走这里。做防抖/冷却，避免
    /// Wi-Fi 抖动或连续 panic 时反复重连。
    func requestReconnect(reason: String,
                          busyTitle: String = "VPN：网络变化，正在重连…") {
        guard !quitting, desiredProfileID != nil else { return }
        // 网络回调和刷新兜底可能重复触发，只在第一次进入排队时记日志
        if !pendingNetworkReconnect && !reconnectScheduled {
            logLine("reconnect requested: \(reason) (busy=\(busy) waiting=\(waitingReady))")
        }

        if busy || waitingReady {
            pendingNetworkReconnect = true
            return
        }
        if Date().timeIntervalSince(lastReconnectAt) < 20 {
            pendingNetworkReconnect = true
            schedulePendingReconnect()
            return
        }
        performReconnect(busyTitle: busyTitle)
    }

    func schedulePendingReconnect() {
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        let wait = max(0, 20 - Date().timeIntervalSince(lastReconnectAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.requestReconnect(reason: "pending")
        }
    }

    /// 网络切换会换掉底层 TCP 的源地址，旧会话没法恢复（zju-connect 自己重拨
    /// 还会 panic）。唯一可靠的办法是完整断开再连接。
    private func performReconnect(busyTitle: String) {
        guard !busy, !waitingReady, !quitting, let sel = desiredSelection() else {
            pendingNetworkReconnect = false
            return
        }
        guard let backend = BackendRegistry.backend(for: sel.profile) else {
            clearDesiredProfile()
            return
        }
        guard loadCredential(for: sel.id) != nil else {
            logLine("auto-reconnect skipped: no credential")
            clearDesiredProfile()
            return
        }
        guard consecutiveReconnects < 3 else {
            logLine("auto-reconnect stopped after \(consecutiveReconnects) attempts; "
                    + "network may still be unstable, please reconnect manually")
            clearDesiredProfile()
            return
        }

        pendingNetworkReconnect = false
        lastReconnectAt = Date()
        consecutiveReconnects += 1
        let now = NetworkSignature.current()
        logLine("auto-reconnect \(consecutiveReconnects)/3: \(sel.profile.name) (\(sel.id)) "
                + "network \(connectSignature.isEmpty ? "-" : connectSignature) -> "
                + "\(now.isEmpty ? "-" : now)")
        beginBusy(busyTitle)

        DispatchQueue.global().async {
            let (code, out) = run("/usr/bin/sudo", ["-n", backend.disconnectScript])
            if code != 0 {
                logLine("auto-reconnect: zc-vpn-off failed (\(code)): \(out)")
            }
            DispatchQueue.main.async {
                guard !self.quitting else {
                    self.finishBusy()
                    return
                }
                self.startConnect(sel)
            }
        }
    }

    /// 由 NetworkMonitor 在主线程调用。
    func networkPathChanged() {
        requestReconnect(reason: "network changed")
    }

    /// 由 TunnelProcessWatcher 在主线程调用：包装脚本（zju-connect）意外退出。
    /// 注意 pidfile 里是包装脚本 PID，v1.5 的 zc-tun.sh 用 `wait` 阻塞，
    /// panic 后会立即收尾退出，所以这里收到事件时隧道已经不可用了。
    func tunnelProcessExited() {
        guard !quitting else { return }
        let shouldReconnect = desiredProfileID != nil && !userDisconnected
            && !busy && !waitingReady
        logLine("tunnel process exited (auto-reconnect=\(shouldReconnect))")
        if shouldReconnect {
            // 先不 refresh：重连流程自己会跑 zc-vpn-off 收尾，避免和
            // repairStaleStateIfIdle 里的兜底还原并发改 DNS。
            requestReconnect(reason: "tunnel process exited",
                             busyTitle: "VPN：连接中断，正在重连…")
            if !busy { refresh() }  // 冷却期内没立刻重连时，先把图标纠正过来
        } else {
            refresh()
        }
    }
}
