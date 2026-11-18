// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

// MARK: - 自启动、日志与退出

extension AppDelegate {
    func ensureLoginItemPlist() {
        let label = "com.lcssos.vpnmenu"
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        let path = dir + "/" + label + ".plist"
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(exe)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>

        """
        if let old = try? String(contentsOfFile: path, encoding: .utf8), old == plist { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? plist.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @objc func openLog() {
        let fm = FileManager.default
        let logFile = currentTunnelBackend().logFile
        if fm.fileExists(atPath: logFile) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logFile))
        } else {
            let dir = (logFile as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    /// 退出前先断开隧道。用 `.terminateLater` 让系统等待异步清理完成：
    /// 菜单退出、⌘Q、AppleScript quit、注销/关机都会经过这里。
    /// zc-vpn-off 要等包装脚本收尾（通常不到 1 秒，极端情况 10 秒后才 SIGKILL），
    /// 所以放到后台执行，期间菜单显示“断开中…”。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 没有隧道时直接退出；busy 时可能连接命令还在飞，交给 zc-vpn-off 兜底
        guard busy || BackendRegistry.anyActiveProcess() else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
        clearDesiredProfile()
        networkMonitor?.stop()
        beginBusy("VPN：断开中…")
        let backend = currentTunnelBackend()
        DispatchQueue.global().async {
            let (code, out) = run("/usr/bin/sudo", ["-n", backend.disconnectScript])
            DispatchQueue.main.async {
                if code != 0 {
                    logLine("quit: zc-vpn-off failed (\(code)): \(out)")
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text.isEmpty ? "未知错误" : String(text.prefix(1200))
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
