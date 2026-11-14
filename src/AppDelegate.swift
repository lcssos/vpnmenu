// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

/// 菜单栏 App 的协调者：持有菜单与运行状态，具体功能拆到同名扩展文件里。
/// - AppDelegate+MenuBar.swift       图标、旋转动画、状态文字
/// - AppDelegate+Profiles.swift      配置菜单与导入/导出/删除
/// - AppDelegate+Connection.swift    连接/断开/等待就绪
/// - AppDelegate+Account.swift       钥匙串账号录入
/// - AppDelegate+Install.swift       组件安装
/// - AppDelegate+Lifecycle.swift     自启动、日志、退出
final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var statusLine: NSMenuItem!
    var connectItem: NSMenuItem!
    var disconnectItem: NSMenuItem!
    var reinstallItem: NSMenuItem!
    var timer: Timer?
    var animTimer: Timer?
    var busyFrames: [NSImage] = []
    var busyFrameIndex = 0
    var busy = false
    var waitingReady = false   // 连接命令已返回，正在等隧道就绪
    var cancelWait = false     // 用户主动断开，抑制“连接失败”提示
    var quitting = false       // 正在断开并退出
    var lastIconLog = ""

    let monitor = VPNMonitor()

    // 配置（只从本机目录读取）
    var profileMenuItem: NSMenuItem!
    var profilesMenu: NSMenu!
    var profiles: [(id: String, profile: Profile)] = []
    var selectedID: String?
    var profilesSignature = ""
    // 配置目录的扫描节流：目录 mtime 变化时立即重扫，另外每 60 秒兜底重扫一次
    // （覆盖直接编辑已有 JSON 的场景——这种情况不会改变目录 mtime）。
    var profilesDirMTime: Date?
    var profilesScanTime: Date?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "检测中…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        connectItem = NSMenuItem(title: "连接", action: #selector(connect), keyEquivalent: "c")
        connectItem.target = self
        menu.addItem(connectItem)

        disconnectItem = NSMenuItem(title: "断开", action: #selector(disconnect), keyEquivalent: "d")
        disconnectItem.target = self
        menu.addItem(disconnectItem)

        menu.addItem(.separator())

        profileMenuItem = NSMenuItem(title: "配置", action: nil, keyEquivalent: "")
        profilesMenu = NSMenu(title: "配置")
        profileMenuItem.submenu = profilesMenu
        menu.addItem(profileMenuItem)

        let accountItem = NSMenuItem(title: "设置账号…", action: #selector(setAccount),
                                     keyEquivalent: "")
        accountItem.target = self
        menu.addItem(accountItem)

        let logItem = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        reinstallItem = NSMenuItem(title: "重新安装组件…", action: #selector(reinstall),
                                   keyEquivalent: "")
        reinstallItem.target = self
        menu.addItem(reinstallItem)

        let quitItem = NSMenuItem(title: "退出并断开 VPN", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        ensureLoginItemPlist()
        refresh()

        // 调试：--dump-icon <path> [--disconnected]
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--dump-icon") {
            let path = idx + 1 < args.count ? args[idx + 1] : "/tmp/vpnmenu-icon.png"
            let connected = !args.contains("--disconnected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.dumpIcon(connected: connected, to: path)
                NSApp.terminate(nil)
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // 只有一个配置时，启动后自动连接（登录自启的常见场景）。
        // 等一次轮询稳定后再做，避免和启动时的状态检查抢。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.autoConnectIfNeeded()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - 状态

    func refresh() {
        reloadProfiles()
        let processAlive = monitor.processAlive()
        let ready = monitor.currentPID().map { monitor.tunnelReady($0) } ?? false
        let connected = processAlive && ready
        // DNS 兜底只在完全没有包装脚本时做；连接中 / 已连接都不能碰
        if !processAlive && monitor.hasStaleDNS() && !busy {
            monitor.repairStaleDNS()
        }
        connectItem.isEnabled = !processAlive && !busy
        // 启动等待期间也允许断开：隧道迟迟不就绪时用户要能取消
        disconnectItem.isEnabled = processAlive && (!busy || waitingReady)
        reinstallItem.isEnabled = !busy
        // 操作进行中：保留「连接中…/断开中…」文字和旋转图标，不被轮询覆盖
        guard !busy else { return }
        if connected {
            stopBusyAnimation()
            statusLine.title = "VPN：已连接"
            setIcon(connected: true)
        } else if processAlive {
            statusLine.title = "VPN：连接中…"
            // 连接不一定由本进程发起（例如 App 重启时隧道正在建立），
            // 只要还没就绪就让图标持续闪烁。
            startBusyAnimation()
        } else {
            stopBusyAnimation()
            statusLine.title = profiles.isEmpty ? "VPN：未配置" : "VPN：未连接"
            setIcon(connected: false)
        }
    }
}
