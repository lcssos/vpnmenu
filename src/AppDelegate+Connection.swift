// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

// MARK: - 连接 / 断开

extension AppDelegate {
    @objc func connect() {
        guard !busy else { return }
        guard let sel = selectedProfile() else {
            showNoProfile()
            return
        }
        consecutiveReconnects = 0  // 用户手动发起，重置自动重连预算
        startConnect(sel)
    }

    /// 启动时的自动连接：只在「本机只有一个配置、凭据已在钥匙串、组件已安装、
    /// 当前没有活动隧道」时执行。缺凭据/未安装组件时静默跳过，避免登录时弹窗。
    func autoConnectIfNeeded() {
        guard !busy, !quitting else { return }
        reloadProfiles(force: true)
        guard profiles.count == 1 else { return }
        let sel = profiles[0]
        guard BackendRegistry.live() == nil else { return }
        guard let backend = BackendRegistry.backend(for: sel.profile) else { return }
        guard FileManager.default.fileExists(atPath: backend.sudoersPath) else {
            logLine("auto-connect skipped: sudoers not installed")
            return
        }
        guard loadCredential(for: sel.id) != nil else {
            logLine("auto-connect skipped: no credential for \(sel.id)")
            return
        }
        logLine("auto-connect: \(sel.profile.name)")
        startConnect(sel)
    }

    func startConnect(_ sel: (id: String, profile: Profile)) {
        // 凭据只在钥匙串里；没有就先让用户录入
        guard let cred = loadCredential(for: sel.id) else {
            if promptCredential(for: sel) { startConnect(sel) }
            return
        }
        guard let backend = BackendRegistry.backend(for: sel.profile) else {
            alert("无法连接", "不支持的 VPN 类型：\(sel.profile.backendID)")
            return
        }
        userDisconnected = false
        armDesiredProfile(sel)
        connectSignature = NetworkSignature.current()
        tunnelBackend = backend
        beginBusy("VPN：连接中…")

        let payload = backend.payload(sel.profile, cred)
        DispatchQueue.global().async {
            let (code, out) = runWithInput("/usr/bin/sudo", ["-n", backend.connectScript], payload)
            DispatchQueue.main.async {
                if code == 0 {
                    self.waitForConnected(backend: backend)
                } else if self.needsInstall(backend, out) {
                    self.askInstall { ok in
                        if ok {
                            self.startAfterInstall(sel)
                        } else {
                            self.clearDesiredProfile()
                            self.finishBusy()
                        }
                    }
                } else {
                    self.clearDesiredProfile()
                    self.finishBusy()
                    self.alert("连接失败", out)
                }
            }
        }
    }

    private func startAfterInstall(_ sel: (id: String, profile: Profile)) {
        guard let backend = BackendRegistry.backend(for: sel.profile) else {
            clearDesiredProfile()
            alert("无法连接", "不支持的 VPN 类型：\(sel.profile.backendID)")
            return
        }
        userDisconnected = false
        armDesiredProfile(sel)
        connectSignature = NetworkSignature.current()
        tunnelBackend = backend
        beginBusy("VPN：连接中…")
        DispatchQueue.global().async {
            guard let cred = loadCredential(for: sel.id) else {
                DispatchQueue.main.async {
                    self.clearDesiredProfile()
                    self.finishBusy()
                    self.alert("缺少账号", "请先在菜单栏「设置账号…」里录入 VPN 账号和密码。")
                }
                return
            }
            let payload = backend.payload(sel.profile, cred)
            let (code, out) = runWithInput("/usr/bin/sudo", ["-n", backend.connectScript], payload)
            DispatchQueue.main.async {
                if code == 0 {
                    self.waitForConnected(backend: backend)
                } else {
                    self.clearDesiredProfile()
                    self.finishBusy()
                    self.alert("连接失败", out)
                }
            }
        }
    }

    private func showNoProfile() {
        let a = NSAlert()
        a.messageText = "还没有 VPN 配置"
        a.informativeText = """
        配置不随 App 分发，也不在公开仓库里。
        请导入一份 JSON 配置（服务器、端口、需要走隧道的域名）。
        账号密码随后在「设置账号…」里录入，保存在钥匙串。
        """
        a.addButton(withTitle: "导入配置…")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { importProfileAction() }
    }

    @objc func disconnect() {
        if waitingReady {
            // 取消「等待就绪」：后台循环会因进程消失而退出，别再弹失败提示
            cancelWait = true
            waitingReady = false
        } else if busy {
            return
        }
        // 用户明确要断开：之后即使网络变化也不能自动连回来
        userDisconnected = true
        clearDesiredProfile()
        beginBusy("VPN：断开中…")

        let backend = currentTunnelBackend()
        DispatchQueue.global().async {
            let (code, out) = run("/usr/bin/sudo", ["-n", backend.disconnectScript])
            DispatchQueue.main.async {
                if code != 0 && self.needsInstall(backend, out) {
                    self.askInstall { ok in
                        if ok { self.stopAfterInstall() } else { self.finishBusy() }
                    }
                } else {
                    self.finishBusy()
                }
            }
        }
    }

    private func stopAfterInstall() {
        let backend = currentTunnelBackend()
        DispatchQueue.global().async {
            _ = run("/usr/bin/sudo", ["-n", backend.disconnectScript])
            DispatchQueue.main.async { self.finishBusy() }
        }
    }

    private func waitForConnected(backend: VPNBackend) {
        waitingReady = true
        cancelWait = false
        DispatchQueue.global().async {
            var sawProcess = false
            var processDied = false
            // utun 就绪通常几秒；90 秒覆盖 DNS 等待和多个域名的重试上限。
            // 0.25 秒轮询：就绪标记写入后能立刻反映到图标，不必按整秒等。
            for i in 0..<360 {
                Thread.sleep(forTimeInterval: 0.25)
                if backend.readyVerified() { break }
                if backend.processPresent() {
                    sawProcess = true
                } else if sawProcess || i >= 20 {
                    processDied = true  // 启动后很快退出，或 5 秒内根本没起来
                    break
                }
            }
            DispatchQueue.main.async {
                self.waitingReady = false
                guard !self.quitting else { return }  // 退出流程自己会终止 App
                if !processDied && backend.readyVerified() {
                    // 连接期间网络又变了：新会话可能还建在旧路径上，等收尾后重连；
                    // 否则清掉期间累积的 pending，避免刚连上又重连一次。
                    // 空签名表示当前无法判定物理网络（例如 utun 成了主接口），
                    // 不能据此判断变化。
                    let now = NetworkSignature.current()
                    if !now.isEmpty, now != self.connectSignature {
                        self.pendingNetworkReconnect = true
                    } else {
                        self.pendingNetworkReconnect = false
                    }
                }
                self.finishBusy()
                // 只有「进程中途退出」才算失败；仍在启动（超时未就绪）继续显示“连接中…”，
                // 用户可以断开取消。手动断开时不报失败。
                if processDied && !self.cancelWait {
                    self.clearDesiredProfile()
                    self.alert("连接没有成功",
                               "zju-connect 在隧道就绪前退出了。请打开日志查看原因。")
                }
                self.cancelWait = false
            }
        }
    }

    /// 进入「操作进行中」状态：提示文字 + 图标在实心/空心锁之间切换
    func beginBusy(_ title: String) {
        busy = true
        statusLine.title = title
        connectItem.isEnabled = false
        disconnectItem.isEnabled = false
        reinstallItem.isEnabled = false
        startBusyAnimation()
    }

    func finishBusy() {
        busy = false
        stopBusyAnimation()
        if pendingNetworkReconnect {
            pendingNetworkReconnect = false
            schedulePendingReconnect()
        }
        refresh()
    }
}
