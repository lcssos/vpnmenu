// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

// MARK: - 安装

extension AppDelegate {
    private static let installScript = """
    on run argv
        do shell script "/bin/bash " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) with administrator privileges
    end run
    """

    func needsInstall(_ backend: VPNBackend, _ output: String) -> Bool {
        backend.needsInstall(output: output)
    }

    func askInstall(completion: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = "首次使用需要安装 VPN 组件"
        a.informativeText = """
        接下来会弹出系统管理员密码窗口，只做两件事：
        • 把 App 内组件设为 root 所有
        • 写入免密启停规则（仅针对本 App）

        安装后连接/断开都不再需要密码。
        """
        a.addButton(withTitle: "安装")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else {
            completion(false)
            return
        }
        statusLine.title = "VPN：正在安装…"
        let backend = currentTunnelBackend()
        DispatchQueue.global().async {
            let (code, out) = run("/usr/bin/osascript",
                                  ["-e", Self.installScript, backend.installScript,
                                   backend.installDir, NSUserName()])
            let ok = (code == 0) && out.contains("INSTALL_OK")
            DispatchQueue.main.async {
                if !ok { self.alert("安装失败", out) }
                completion(ok)
            }
        }
    }

    @objc func reinstall() {
        let a = NSAlert()
        a.messageText = "重新安装组件？"
        a.informativeText = "会重新写入权限和免密规则（需要管理员密码）。移动过 App 位置后用它修复。"
        a.addButton(withTitle: "重新安装")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        beginBusy("VPN：正在安装…")
        let backend = currentTunnelBackend()
        DispatchQueue.global().async {
            let (code, out) = run("/usr/bin/osascript",
                                  ["-e", Self.installScript, backend.installScript,
                                   backend.installDir, NSUserName()])
            let ok = (code == 0) && out.contains("INSTALL_OK")
            DispatchQueue.main.async {
                self.finishBusy()
                if ok {
                    self.alert("安装完成", "组件已就绪，可以正常连接了。")
                } else {
                    self.alert("安装失败", out)
                }
            }
        }
    }
}
