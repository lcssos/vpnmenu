// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only
//
// 入口：命令行辅助模式 → 单实例锁 → 菜单栏 App。
// 其它源码按职责拆分：
//   AppDelegate.swift / AppDelegate+*.swift   界面与业务
//   Backends/                                 后端协议、注册表、zju-connect 实现
//   Profile.swift / Keychain.swift            配置与凭据
//   Process.swift / Logging.swift             子进程与日志
//   CommandLineTool.swift / SingleInstance.swift

import Cocoa

runCommandLineToolIfRequested()

// 已有实例时第二个进程直接退出：不碰 VPN，也不创建第二个菜单栏图标。
// 这里不能用 NSApp.terminate —— 那会走退出流程，把主实例正在用的隧道断掉。
guard acquireInstanceLock() else {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
