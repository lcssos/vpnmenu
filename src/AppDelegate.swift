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
    // 按连接状态缓存模板图标，避免每次刷新重复生成 SF Symbol 位图
    var iconCache: [String: NSImage] = [:]
    var tunnelBackend: VPNBackend?

    // 网络切换后的自动重连（见 AppDelegate+Network.swift）
    var networkMonitor: NetworkMonitor?
    var desiredProfileID: String?      // 非空 = 我们期望隧道保持连接
    var desiredProfile: Profile?       // 配置被删/改名时退回连接时的快照
    var userDisconnected = false       // 用户手动断开过，直到下次连接前不再自动接管
    var pendingNetworkReconnect = false
    var reconnectScheduled = false
    var lastReconnectAt = Date.distantPast
    var connectSignature = ""          // 发起连接时的物理网络签名
    var consecutiveReconnects = 0      // 连续自动重连次数，稳定 60 秒后清零
    var connectedSince: Date?          // 本次“已连接”开始的时间

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

        // 监听物理网络变化：Wi-Fi / 有线切换后底层 TCP 已失效，需要完整重连。
        networkMonitor = NetworkMonitor { [weak self] in
            self?.networkPathChanged()
        }
        networkMonitor?.start()

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

        // 暂时停用 5 秒状态轮询（需要时取消注释即可恢复）。
        // 注意：停用后，外部启停隧道、进程崩溃、脚本健康标记、配置目录直改等
        // 都不会被自动发现；只有菜单操作、连接/断开收尾、网络变化回调才会 refresh。
        // 5 秒轮询：状态变化（外部连接/退出、panic 后的 DNS 修复）最长延迟 5 秒。
        // tolerance 允许系统把这几次唤醒合并到别的定时器上，省电；代价是再多最多 1 秒延迟。
        // timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
        //     // 轮询里的临时字符串/字典/文件内容在下一次 tick 前就释放，不留在 autorelease 池里
        //     autoreleasepool { self?.refresh() }
        // }
        // timer?.tolerance = 1.0

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
        // 兜底检查一次网络签名（部分 Wi-Fi 漫游不会产生 NWPath 事件）
        networkMonitor?.checkNow()

        let live = BackendRegistry.live()
        let processAlive = live != nil
        let connected = live?.status.ready ?? false
        // 残留状态修复只在完全没有隧道时做；连接中 / 已连接都不能碰
        if !processAlive {
            BackendRegistry.repairStaleStatesIfIdle(busy: busy)
        }
        // 连续自动重连预算：连接稳定 60 秒后清零，避免网络疯狂抖动时无限重连
        if connected {
            if connectedSince == nil { connectedSince = Date() }
            if consecutiveReconnects > 0,
               let since = connectedSince,
               Date().timeIntervalSince(since) >= 60 {
                consecutiveReconnects = 0
            }
        } else {
            connectedSince = nil
        }
        // App 重启时隧道可能已经在跑（例如 CLI 或上次没退干净）：把当前选中配置
        // 记成期望状态，这样之后的网络切换仍能自动重连。
        if connected, desiredProfileID == nil, !userDisconnected, !busy,
           let sel = selectedProfile() {
            armDesiredProfile(sel)
        }
        if !processAlive && !BackendRegistry.anyActiveProcess() && !busy && !waitingReady {
            tunnelBackend = nil
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

    // MARK: - 后端选择

    func selectedBackend() -> VPNBackend? {
        guard let id = selectedID,
              let hit = profiles.first(where: { $0.id == id }) else { return nil }
        return BackendRegistry.backend(for: hit.profile)
    }

    /// 当前实际要操作的后端：运行中的隧道 > 连接在飞 > 选中配置 > 第一个注册后端。
    /// 这里用 processPresent 而不是带 ps 校验的 alivePID：断开/退出宁可多停一次，
    /// 也不能因为命令行校验失败而把操作打到另一个后端上。
    func currentTunnelBackend() -> VPNBackend {
        BackendRegistry.resolve(alive: BackendRegistry.running(),
                                pending: tunnelBackend,
                                selected: selectedBackend(),
                                registered: BackendRegistry.all)!
    }

    func isConnected() -> Bool { BackendRegistry.live() != nil }
}
