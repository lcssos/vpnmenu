// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// App 内组件与运行期文件的固定位置，集中在这里避免各处拼路径。
enum VPMPaths {
    /// 所有组件都在 App 内部：Contents/Resources/vpn/
    static let vpnDir: String = {
        if let res = Bundle.main.resourceURL {
            return res.appendingPathComponent("vpn").path
        }
        return "/Applications/VPNMenu.app/Contents/Resources/vpn"
    }()

    static var on: String { vpnDir + "/zc-vpn-on" }
    static var off: String { vpnDir + "/zc-vpn-off" }
    static var install: String { vpnDir + "/install.sh" }

    /// root 包装脚本 zc-tun.sh 的 pidfile 与 utun 就绪标记
    static let statusPidFile = "/var/run/zju-connect.pid"
    static let readyFile = "/var/run/zju-connect.ready"

    static let sudoers = "/etc/sudoers.d/vpnmenu"
    static var logFile: String { NSHomeDirectory() + "/Library/Logs/VPNMenu/zju-connect.log" }
}
