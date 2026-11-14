// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa
import Darwin
import Security

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// 通过 stdin 向子进程输入数据（密码不经过 argv，不会出现在进程列表里）
@discardableResult
func runWithInput(_ launchPath: String, _ args: [String], _ input: String) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe()
    let inp = Pipe()
    p.standardOutput = out
    p.standardError = out
    p.standardInput = inp
    do { try p.run() } catch { return (-1, "\(error)") }
    inp.fileHandleForWriting.write(Data(input.utf8))
    try? inp.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - 本机配置（不进仓库、也不进 App 包）

/// 连接参数只保存在本机：~/Library/Application Support/VPNMenu/profiles/<uuid>.json
/// 账号密码不在这里，见下方钥匙串部分。
struct Profile: Codable {
    var schema: Int?
    var name: String
    var server: String
    var port: Int?
    var tunInterface: String?
    var socksBind: String?
    var httpBind: String?
    var domains: [String]?
    var proxyDomains: [String]?

    var portValue: Int { port ?? 4430 }
    var domainList: [String] { domains ?? [] }
    var proxyDomainList: [String] { proxyDomains ?? [] }
}

enum ProfileValidation {
    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static func isHost(_ s: String) -> Bool {
        s.count <= 253 && matches(s, #"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$"#)
    }

    static func isBind(_ s: String) -> Bool {
        matches(s, #"^[A-Za-z0-9.]+:[0-9]{1,5}$"#)
    }

    /// 返回 nil 表示合法
    static func error(for p: Profile) -> String? {
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "配置名称不能为空" }
        if name.count > 80 { return "配置名称过长" }
        if !isHost(p.server) { return "服务器地址不合法：\(p.server)" }
        let port = p.portValue
        if port < 1 || port > 65535 { return "端口不合法：\(port)" }
        if let v = p.tunInterface, !v.isEmpty, !matches(v, #"^utun[0-9]{1,3}$"#) {
            return "隧道接口名不合法：\(v)"
        }
        if let v = p.socksBind, !v.isEmpty, !isBind(v) { return "SOCKS 监听地址不合法：\(v)" }
        if let v = p.httpBind, !v.isEmpty, !isBind(v) { return "HTTP 监听地址不合法：\(v)" }
        let all = p.domainList + p.proxyDomainList
        if all.count > 500 { return "域名数量过多" }
        for d in all where !isHost(d) {
            return "域名不合法：\(d)"
        }
        return nil
    }
}

enum ProfileStore {
    static let selectedKey = "selectedProfileID"

    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VPNMenu/profiles", isDirectory: true)
    }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func list() -> [(id: String, profile: Profile)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(id: String, profile: Profile)] = []
        for n in names where n.hasSuffix(".json") && !n.hasPrefix(".") {
            let url = dir.appendingPathComponent(n)
            guard let data = try? Data(contentsOf: url),
                  let p = try? JSONDecoder().decode(Profile.self, from: data),
                  ProfileValidation.error(for: p) == nil else { continue }
            out.append(((n as NSString).deletingPathExtension, p))
        }
        return out.sorted { $0.profile.name.localizedStandardCompare($1.profile.name) == .orderedAscending }
    }

    static func encode(_ p: Profile) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(p)
    }

    /// 导入时总是新建 id，避免覆盖已有配置。
    static func importProfile(from url: URL) -> (id: String?, error: String?) {
        guard let data = try? Data(contentsOf: url) else { return (nil, "无法读取所选文件") }
        guard let p = try? JSONDecoder().decode(Profile.self, from: data) else {
            return (nil, "不是有效的配置 JSON")
        }
        if let err = ProfileValidation.error(for: p) { return (nil, err) }
        if let id = save(p) { return (id, nil) }
        return (nil, "无法写入配置目录")
    }

    static func save(_ p: Profile) -> String? {
        ensureDir()
        guard let data = encode(p) else { return nil }
        let id = UUID().uuidString.lowercased()
        let url = dir.appendingPathComponent(id + ".json")
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return id
        } catch {
            return nil
        }
    }

    static func write(_ p: Profile, to url: URL) -> Bool {
        guard let data = encode(p) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".json"))
    }

    /// 当前选中的配置；保存的 id 不存在时退回第一个。
    static func selected() -> (id: String, profile: Profile)? {
        let all = list()
        guard !all.isEmpty else { return nil }
        if let saved = UserDefaults.standard.string(forKey: selectedKey),
           let hit = all.first(where: { $0.id == saved }) {
            return hit
        }
        return all.first
    }
}

// MARK: - 钥匙串里的 VPN 凭据（按配置分开）

let legacyCredentialService = "com.lcssos.vpnmenu.credential"

func credentialService(for profileID: String) -> String {
    "\(legacyCredentialService).\(profileID)"
}

func loadCredential(service: String) -> (user: String, pass: String)? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnAttributes as String: true,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
          let d = item as? [String: Any],
          let user = d[kSecAttrAccount as String] as? String,
          let data = d[kSecValueData as String] as? Data,
          let pass = String(data: data, encoding: .utf8) else { return nil }
    return (user, pass)
}

func saveCredential(service: String, user: String, pass: String) -> Bool {
    let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
    ]
    SecItemDelete(base as CFDictionary)
    var add = base
    add[kSecAttrAccount as String] = user
    add[kSecValueData as String] = Data(pass.utf8)
    add[kSecAttrLabel as String] = "VPNMenu 账号"
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
}

func deleteCredential(service: String) {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
    ]
    SecItemDelete(q as CFDictionary)
}

/// 旧版本只存一个全局条目；首次读取时迁移到当前配置名下并删除旧条目，
/// 避免以后再导入的配置误用同一份凭据。
func loadCredential(for profileID: String) -> (user: String, pass: String)? {
    let service = credentialService(for: profileID)
    if let c = loadCredential(service: service) { return c }
    guard let legacy = loadCredential(service: legacyCredentialService) else { return nil }
    if saveCredential(service: service, user: legacy.user, pass: legacy.pass) {
        deleteCredential(service: legacyCredentialService)
    }
    return legacy
}

/// 通过 stdin 交给 root 脚本的 key=value 协议；脚本只做白名单解析，绝不 source 配置文件。
func connectionPayload(_ p: Profile, _ c: (user: String, pass: String)) -> String {
    var lines = [
        "ACCOUNT=\(c.user)",
        "PASSWORD=\(c.pass)",
        "SERVER=\(p.server)",
        "PORT=\(p.portValue)",
    ]
    if let v = p.tunInterface, !v.isEmpty { lines.append("TUN_IF=\(v)") }
    if let v = p.socksBind, !v.isEmpty { lines.append("SOCKS_BIND=\(v)") }
    if let v = p.httpBind, !v.isEmpty { lines.append("HTTP_BIND=\(v)") }
    for d in p.domainList { lines.append("DOMAIN=\(d)") }
    for d in p.proxyDomainList { lines.append("PROXY_DOMAIN=\(d)") }
    return lines.joined(separator: "\n") + "\n"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var connectItem: NSMenuItem!
    private var disconnectItem: NSMenuItem!
    private var reinstallItem: NSMenuItem!
    private var timer: Timer?
    private var animTimer: Timer?
    private var busyFrames: [NSImage] = []
    private var busyFrameIndex = 0
    private var busy = false
    private var lastIconLog = ""
    private var lastDNSRepair = Date.distantPast

    // 配置（只从本机目录读取）
    private var profileMenuItem: NSMenuItem!
    private var profilesMenu: NSMenu!
    private var profiles: [(id: String, profile: Profile)] = []
    private var selectedID: String?
    private var profilesSignature = ""
    // 配置目录的扫描节流：目录 mtime 变化时立即重扫，另外每 60 秒兜底重扫一次
    // （覆盖直接编辑已有 JSON 的场景——这种情况不会改变目录 mtime）。
    private var profilesDirMTime: Date?
    private var profilesScanTime: Date?

    // 所有组件都在 App 内部：Contents/Resources/vpn/
    private let vpnDir: String = {
        if let res = Bundle.main.resourceURL {
            return res.appendingPathComponent("vpn").path
        }
        return "/Applications/VPNMenu.app/Contents/Resources/vpn"
    }()
    private var onPath: String { vpnDir + "/zc-vpn-on" }
    private var offPath: String { vpnDir + "/zc-vpn-off" }
    private var installPath: String { vpnDir + "/install.sh" }

    // 状态检查在进程内完成，不再每 2 秒 fork 一个 zc-vpn-status。
    // pidfile 里是 root 包装脚本 zc-tun.sh 的 PID；`kill(0)` 做存活检查，
    // `sysctl` 读启动时间识别 PID 复用，`ps` 只在首次见到某个进程实例时校验一次命令行。
    private let statusPidFile = "/var/run/zju-connect.pid"
    private var statusVerifiedPID: pid_t = -1
    private var statusVerifiedStart: UInt64?
    private var statusVerifiedAlive = false
    private var logPath: String { NSHomeDirectory() + "/Library/Logs/VPNMenu/zju-connect.log" }
    private let sudoersPath = "/etc/sudoers.d/vpnmenu"

    private static let installScript = """
    on run argv
        do shell script "/bin/bash " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) with administrator privileges
    end run
    """

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

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
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

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - 配置菜单

    /// 每 2 秒的刷新会调用这里，但只有「目录 mtime 变了 / 第一次扫描 / 距上次扫描
    /// 超过 60 秒 / 显式 force」时才真正读盘并解码 JSON，避免每 2 秒全量解析配置。
    private func reloadProfiles(force: Bool = false) {
        let now = Date()
        let attrs = try? FileManager.default.attributesOfItem(atPath: ProfileStore.dir.path)
        let mtime = attrs?[.modificationDate] as? Date
        let needsScan = force
            || profilesScanTime == nil
            || mtime != profilesDirMTime
            || now.timeIntervalSince(profilesScanTime ?? now) > 60
        if needsScan {
            profiles = ProfileStore.list()
            profilesDirMTime = mtime
            profilesScanTime = now
        }
        let ids = profiles.map { $0.id }
        if let saved = UserDefaults.standard.string(forKey: ProfileStore.selectedKey),
           ids.contains(saved) {
            selectedID = saved
        } else {
            selectedID = profiles.first?.id
        }
        let sig = profiles.map { "\($0.id):\($0.profile.name)" }.joined(separator: "|")
            + "#\(selectedID ?? "-")"
        guard sig != profilesSignature else { return }
        profilesSignature = sig
        rebuildProfilesMenu()
    }

    private func rebuildProfilesMenu() {
        profilesMenu.removeAllItems()
        if profiles.isEmpty {
            let none = NSMenuItem(title: "尚未导入配置", action: nil, keyEquivalent: "")
            none.isEnabled = false
            profilesMenu.addItem(none)
        } else {
            for p in profiles {
                let it = NSMenuItem(title: p.profile.name,
                                    action: #selector(selectProfile(_:)),
                                    keyEquivalent: "")
                it.target = self
                it.representedObject = p.id
                it.state = (p.id == selectedID) ? .on : .off
                profilesMenu.addItem(it)
            }
        }
        profilesMenu.addItem(.separator())

        let imp = NSMenuItem(title: "导入配置…", action: #selector(importProfileAction),
                             keyEquivalent: "")
        imp.target = self
        profilesMenu.addItem(imp)

        let exp = NSMenuItem(title: "导出当前配置…", action: #selector(exportProfileAction),
                             keyEquivalent: "")
        exp.target = self
        exp.isEnabled = selectedID != nil
        profilesMenu.addItem(exp)

        let del = NSMenuItem(title: "删除当前配置…", action: #selector(deleteProfileAction),
                             keyEquivalent: "")
        del.target = self
        del.isEnabled = selectedID != nil
        profilesMenu.addItem(del)

        let show = NSMenuItem(title: "显示配置目录", action: #selector(openProfilesDir),
                              keyEquivalent: "")
        show.target = self
        profilesMenu.addItem(show)
    }

    private func selectedProfile() -> (id: String, profile: Profile)? {
        if profiles.isEmpty { reloadProfiles(force: true) }
        if let id = selectedID, let hit = profiles.first(where: { $0.id == id }) {
            return hit
        }
        return profiles.first
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != selectedID else { return }
        guard let target = profiles.first(where: { $0.id == id }) else { return }

        let connected = vpnProcessAlive()
        if connected {
            let a = NSAlert()
            a.messageText = "切换到「\(target.profile.name)」？"
            a.informativeText = "当前 VPN 已连接，切换配置需要先断开，再按新配置重连。"
            a.addButton(withTitle: "断开并重连")
            a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }

        UserDefaults.standard.set(id, forKey: ProfileStore.selectedKey)
        reloadProfiles()
        refresh()
        if connected { switchAndReconnect() }
    }

    private func switchAndReconnect() {
        guard !busy else { return }
        beginBusy("VPN：切换配置…")
        DispatchQueue.global().async {
            _ = run("/usr/bin/sudo", ["-n", self.offPath])
            DispatchQueue.main.async {
                self.finishBusy()
                self.connect()
            }
        }
    }

    // MARK: - 导入 / 导出 / 删除

    @objc private func importProfileAction() {
        let panel = NSOpenPanel()
        panel.title = "导入 VPN 配置"
        panel.message = "选择包含服务器与域名路由的 JSON 配置文件（不含账号密码）。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["json"]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let (id, error) = ProfileStore.importProfile(from: url)
        guard let id = id else {
            alert("导入失败", error ?? "未知错误")
            return
        }
        let name = ProfileStore.list().first(where: { $0.id == id })?.profile.name ?? "新配置"
        let connected = vpnProcessAlive()
        if connected {
            // 不悄悄切走正在使用的配置；断开后再让用户选择
            alert("导入成功", "配置「\(name)」已导入。当前连接仍使用原配置；断开后可在「配置」里切换。")
        } else {
            UserDefaults.standard.set(id, forKey: ProfileStore.selectedKey)
        }
        reloadProfiles(force: true)
        refresh()
    }

    @objc private func exportProfileAction() {
        guard let sel = selectedProfile() else { return }
        let panel = NSSavePanel()
        panel.title = "导出 VPN 配置"
        panel.message = "只导出服务器与域名；账号密码仍在钥匙串里，不会写入文件。"
        let safeName = sel.profile.name.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = safeName + ".json"
        panel.allowedFileTypes = ["json"]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !ProfileStore.write(sel.profile, to: url) {
            alert("导出失败", "无法写入所选位置。")
        }
    }

    @objc private func deleteProfileAction() {
        guard let sel = selectedProfile() else { return }
        let a = NSAlert()
        a.messageText = "删除配置「\(sel.profile.name)」？"
        a.informativeText = "会同时删除这份配置在钥匙串里的账号密码。当前已建立的连接不会自动断开。"
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        ProfileStore.delete(id: sel.id)
        deleteCredential(service: credentialService(for: sel.id))
        UserDefaults.standard.removeObject(forKey: ProfileStore.selectedKey)
        profilesSignature = ""
        reloadProfiles(force: true)
        refresh()
    }

    @objc private func openProfilesDir() {
        ProfileStore.ensureDir()
        NSWorkspace.shared.open(ProfileStore.dir)
    }

    // MARK: - 状态与图标

    private func refresh() {
        reloadProfiles()
        let connected = vpnProcessAlive()
        if !connected && hasStaleVPNDNS() { repairStaleDNS() }
        connectItem.isEnabled = !connected && !busy
        disconnectItem.isEnabled = connected && !busy
        reinstallItem.isEnabled = !busy
        // 操作进行中：保留「连接中…/断开中…」文字和旋转图标，不被轮询覆盖
        guard !busy else { return }
        if connected {
            statusLine.title = "VPN：已连接"
        } else if profiles.isEmpty {
            statusLine.title = "VPN：未配置"
        } else {
            statusLine.title = "VPN：未连接"
        }
        setIcon(connected: connected)
    }

    private func currentVPNPID() -> pid_t? {
        guard let text = try? String(contentsOfFile: statusPidFile, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else { return nil }
        return value
    }

    /// 只做存在性检查（可在后台线程调用）。root 进程对普通用户执行 kill(0) 会返回
    /// EPERM，同样说明进程还活着；ESRCH 才是真的没了。
    private func vpnProcessExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// 读进程启动时间（微秒），用于区分「同一个 PID 的不同进程实例」。
    /// sysctl 对 root 进程也可读；读取失败时返回 nil，退化为只按 PID 缓存。
    private func processStartTime(_ pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let r = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard r == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        return UInt64(info.kp_proc.p_starttime.tv_sec) * 1_000_000
            + UInt64(info.kp_proc.p_starttime.tv_usec)
    }

    /// 等价于原来的 zc-vpn-status，但稳态下不启动任何子进程：
    /// - `kill(pid, 0)` 每次轮询都做（系统调用，成本可忽略）；
    /// - 只有首次见到某个 PID、或启动时间变了（PID 被复用）时，才用一次 `ps` 校验命令行。
    /// 只在主线程调用（缓存不设锁）。
    private func vpnProcessAlive() -> Bool {
        guard let pid = currentVPNPID(), vpnProcessExists(pid) else {
            statusVerifiedPID = -1
            statusVerifiedStart = nil
            statusVerifiedAlive = false
            return false
        }
        let start = processStartTime(pid)
        if pid == statusVerifiedPID && start == statusVerifiedStart {
            return statusVerifiedAlive
        }

        // -ww：不按终端宽度截断命令行
        let (code, out) = run("/bin/ps", ["-ww", "-p", "\(pid)", "-o", "command="])
        guard code == 0 else { return false }  // ps 自身失败：不写缓存，下个 tick 重试
        statusVerifiedPID = pid
        statusVerifiedStart = start
        statusVerifiedAlive = out.contains(vpnDir + "/zc-tun.sh")
        return statusVerifiedAlive
    }

    /// 完整校验（pidfile + 存活 + 命令行），不碰缓存，可在后台线程调用。
    private func vpnProcessVerified() -> Bool {
        guard let pid = currentVPNPID(), vpnProcessExists(pid) else { return false }
        let (code, out) = run("/bin/ps", ["-ww", "-p", "\(pid)", "-o", "command="])
        return code == 0 && out.contains(vpnDir + "/zc-tun.sh")
    }

    /// zju-connect panic 时可能把系统 DNS 留在 2.0.1.x（隧道已死、不可达）。
    private func hasStaleVPNDNS() -> Bool {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return false
        }
        // (?m) 多行模式：只匹配行首的 nameserver
        return text.range(of: #"(?m)^nameserver[ \t]+2\.0\.1\.[0-9]+"#,
                          options: .regularExpression) != nil
    }

    /// zju-connect 在 panic 时不会还原被 -dns-hijack 改写的系统 DNS（留在 2.0.1.x），
    /// 整机域名解析都会失效。调用 zc-vpn-off（sudoers 已放行）按启动前快照兜底还原。
    private func repairStaleDNS() {
        guard !busy, Date().timeIntervalSince(lastDNSRepair) > 30 else { return }
        lastDNSRepair = Date()
        DispatchQueue.global().async {
            _ = run("/usr/bin/sudo", ["-n", self.offPath])
        }
    }

    private func setIcon(connected: Bool) {
        guard let button = item.button else { return }
        let dark = menuBarIsDark()
        let name = connected ? "lock.shield.fill" : "lock.shield"
        let color = iconColor(dark: dark)
        if let img = tintedSymbol(name, color: color) {
            button.image = img
            button.title = ""
            button.contentTintColor = nil
            button.needsDisplay = true
        } else {
            button.image = nil
            button.title = "VPN"
            button.contentTintColor = dark ? .white : .black
        }

        let flag = "connected=\(connected) dark=\(dark)"
        if flag != lastIconLog {
            lastIconLog = flag
            logLine("icon \(flag) appearance=\(button.effectiveAppearance.name.rawValue) color=\(color)")
        }
    }

    private func menuBarIsDark() -> Bool {
        let appearance = item.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func iconColor(dark: Bool) -> NSColor {
        dark ? .white : .black
    }

    private func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "VPN")?
            .withSymbolConfiguration(cfg) else { return nil }
        let out = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    private func logLine(_ s: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("VPNMenu.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func dumpIcon(connected: Bool, to path: String) {
        let dark = menuBarIsDark()
        let color = iconColor(dark: dark)
        let name = connected ? "lock.shield.fill" : "lock.shield"
        guard let icon = tintedSymbol(name, color: color) else { return }
        let scale: CGFloat = 10
        let out = NSImage(size: NSSize(width: icon.size.width * scale,
                                       height: icon.size.height * scale),
                          flipped: false) { rect in
            NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1).setFill()
            rect.fill()
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: rect)
            return true
        }
        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - 连接 / 断开

    @objc private func connect() {
        guard !busy else { return }
        guard let sel = selectedProfile() else {
            showNoProfile()
            return
        }
        startConnect(sel)
    }

    private func startConnect(_ sel: (id: String, profile: Profile)) {
        // 凭据只在钥匙串里；没有就先让用户录入
        guard let cred = loadCredential(for: sel.id) else {
            if promptCredential(for: sel) { startConnect(sel) }
            return
        }
        beginBusy("VPN：连接中…")

        let payload = connectionPayload(sel.profile, cred)
        DispatchQueue.global().async {
            let (code, out) = runWithInput("/usr/bin/sudo", ["-n", self.onPath], payload)
            DispatchQueue.main.async {
                if code == 0 {
                    self.waitForConnected()
                } else if self.needsInstall(out) {
                    self.askInstall { ok in
                        if ok { self.startAfterInstall(sel) } else { self.finishBusy() }
                    }
                } else {
                    self.finishBusy()
                    self.alert("连接失败", out)
                }
            }
        }
    }

    private func startAfterInstall(_ sel: (id: String, profile: Profile)) {
        beginBusy("VPN：连接中…")
        DispatchQueue.global().async {
            guard let cred = loadCredential(for: sel.id) else {
                DispatchQueue.main.async {
                    self.finishBusy()
                    self.alert("缺少账号", "请先在菜单栏「设置账号…」里录入 VPN 账号和密码。")
                }
                return
            }
            let payload = connectionPayload(sel.profile, cred)
            let (code, out) = runWithInput("/usr/bin/sudo", ["-n", self.onPath], payload)
            DispatchQueue.main.async {
                if code == 0 {
                    self.waitForConnected()
                } else {
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

    @objc private func disconnect() {
        guard !busy else { return }
        beginBusy("VPN：断开中…")

        DispatchQueue.global().async {
            let (code, out) = run("/usr/bin/sudo", ["-n", self.offPath])
            DispatchQueue.main.async {
                if code != 0 && self.needsInstall(out) {
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
        DispatchQueue.global().async {
            _ = run("/usr/bin/sudo", ["-n", self.offPath])
            DispatchQueue.main.async { self.finishBusy() }
        }
    }

    private func waitForConnected() {
        DispatchQueue.global().async {
            for _ in 0..<40 {
                sleep(1)
                if self.vpnProcessVerified() { break }
            }
            DispatchQueue.main.async { self.finishBusy() }
        }
    }

    /// 进入「操作进行中」状态：提示文字 + 图标在实心/空心锁之间切换
    private func beginBusy(_ title: String) {
        busy = true
        statusLine.title = title
        connectItem.isEnabled = false
        disconnectItem.isEnabled = false
        reinstallItem.isEnabled = false
        startBusyAnimation()
    }

    private func startBusyAnimation() {
        guard animTimer == nil else { return }
        let color = iconColor(dark: menuBarIsDark())
        guard let hollow = tintedSymbol("lock.shield", color: color),
              let filled = tintedSymbol("lock.shield.fill", color: color) else { return }

        // 先显示与当前状态相反的那一个，点下去立刻有反馈
        let connectedNow = vpnProcessAlive()
        let ordered = connectedNow ? [hollow, filled] : [filled, hollow]

        // 两个符号的包围盒可能差零点几像素；统一画布，切换时菜单栏图标不会左右跳
        let canvas = NSSize(width: max(hollow.size.width, filled.size.width),
                            height: max(hollow.size.height, filled.size.height))
        busyFrames = ordered.map { centered($0, in: canvas) }
        busyFrameIndex = 0
        applyBusyFrame()

        // .common 模式：打开菜单、弹窗时也能继续切
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self, !self.busyFrames.isEmpty else { return }
            self.busyFrameIndex = (self.busyFrameIndex + 1) % self.busyFrames.count
            self.applyBusyFrame()
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    private func centered(_ image: NSImage, in size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let x = (rect.width - image.size.width) / 2
            let y = (rect.height - image.size.height) / 2
            image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height))
            return true
        }
    }

    private func applyBusyFrame() {
        guard busyFrames.indices.contains(busyFrameIndex), let button = item.button else { return }
        button.image = busyFrames[busyFrameIndex]
        button.needsDisplay = true
    }

    private func stopBusyAnimation() {
        animTimer?.invalidate()
        animTimer = nil
        busyFrames = []
        busyFrameIndex = 0
        item.button?.alphaValue = 1.0
    }

    private func finishBusy() {
        busy = false
        stopBusyAnimation()
        refresh()
    }

    private func needsInstall(_ output: String) -> Bool {
        if !FileManager.default.fileExists(atPath: sudoersPath) { return true }
        let t = output.lowercased()
        return t.contains("password is required") || t.contains("terminal is required")
    }

    // MARK: - 账号（钥匙串）

    @objc private func setAccount() {
        guard let sel = selectedProfile() else {
            alert("还没有配置", "请先在「配置 → 导入配置…」里导入一份配置，再录入账号。")
            return
        }
        _ = promptCredential(for: sel)
    }

    /// 弹出录入框，保存到登录钥匙串。返回是否保存成功。
    @discardableResult
    private func promptCredential(for sel: (id: String, profile: Profile)) -> Bool {
        let service = credentialService(for: sel.id)
        let a = NSAlert()
        a.messageText = "VPN 账号 · \(sel.profile.name)"
        a.informativeText = """
        账号和密码保存在 macOS 登录钥匙串（服务名 \(service)），
        不会写入 App 或配置文件，也不会出现在命令行参数里。
        """
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 62))
        let userField = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        userField.placeholderString = "用户名"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        passField.placeholderString = "密码"
        if let c = loadCredential(for: sel.id) { userField.stringValue = c.user }
        box.addSubview(userField)
        box.addSubview(passField)
        a.accessoryView = box

        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = userField
        guard a.runModal() == .alertFirstButtonReturn else { return false }

        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue
        guard !user.isEmpty, !pass.isEmpty else {
            alert("保存失败", "用户名和密码都不能为空。")
            return false
        }
        guard !pass.contains("\n"), !pass.contains("\r") else {
            alert("保存失败", "密码里不能有换行符。")
            return false
        }
        guard saveCredential(service: service, user: user, pass: pass) else {
            alert("保存失败", "无法写入登录钥匙串。")
            return false
        }
        return true
    }

    // MARK: - 安装

    private func askInstall(completion: @escaping (Bool) -> Void) {
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
        DispatchQueue.global().async {
            let (code, out) = run("/usr/bin/osascript",
                                  ["-e", Self.installScript, self.installPath,
                                   self.vpnDir, NSUserName()])
            let ok = (code == 0) && out.contains("INSTALL_OK")
            DispatchQueue.main.async {
                if !ok { self.alert("安装失败", out) }
                completion(ok)
            }
        }
    }

    @objc private func reinstall() {
        let a = NSAlert()
        a.messageText = "重新安装组件？"
        a.informativeText = "会重新写入权限和免密规则（需要管理员密码）。移动过 App 位置后用它修复。"
        a.addButton(withTitle: "重新安装")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        beginBusy("VPN：正在安装…")
        DispatchQueue.global().async {
            let (code, out) = run("/usr/bin/osascript",
                                  ["-e", Self.installScript, self.installPath,
                                   self.vpnDir, NSUserName()])
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

    // MARK: - 其它

    private func ensureLoginItemPlist() {
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

    @objc private func openLog() {
        let fm = FileManager.default
        if fm.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        } else {
            let dir = (logPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text.isEmpty ? "未知错误" : String(text.prefix(1200))
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - 命令行辅助模式（不启动菜单栏）

let cliArgs = CommandLine.arguments

func printErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// 导入配置（供脚本/部署使用）：--import-profile <文件> [--no-select]
if let idx = cliArgs.firstIndex(of: "--import-profile") {
    guard idx + 1 < cliArgs.count else {
        printErr("用法: VPNMenu --import-profile <配置文件.json> [--no-select]")
        exit(1)
    }
    let url = URL(fileURLWithPath: cliArgs[idx + 1])
    let (id, error) = ProfileStore.importProfile(from: url)
    guard let id = id else {
        printErr("导入失败：\(error ?? "未知错误")")
        exit(1)
    }
    if !cliArgs.contains("--no-select") {
        UserDefaults.standard.set(id, forKey: ProfileStore.selectedKey)
    }
    print(id)
    exit(0)
}

// 列出本机配置
if cliArgs.contains("--list-profiles") {
    let all = ProfileStore.list()
    if all.isEmpty { printErr("没有配置（目录：\(ProfileStore.dir.path)）"); exit(1) }
    let selected = ProfileStore.selected()?.id
    for p in all {
        print("\(p.id == selected ? "*" : " ")\t\(p.id)\t\(p.profile.name)\t\(p.profile.server):\(p.profile.portValue)")
    }
    exit(0)
}

// 为当前选中的配置录入凭据：stdin 两行，用户名、密码
if cliArgs.contains("--set-credential") {
    guard let sel = ProfileStore.selected() else {
        printErr("还没有配置；先用 --import-profile 导入")
        exit(4)
    }
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(),
                       encoding: .utf8) ?? ""
    let lines = input.components(separatedBy: "\n")
    guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else {
        printErr("用法: VPNMenu --set-credential  (stdin 两行: 用户名、密码)")
        exit(1)
    }
    let ok = saveCredential(service: credentialService(for: sel.id),
                            user: lines[0], pass: lines[1])
    exit(ok ? 0 : 1)
}

// 用当前配置 + 钥匙串里的凭据直接连接（调试/验证用）
if cliArgs.contains("--vpn-on") {
    guard let sel = ProfileStore.selected() else {
        printErr("没有配置（目录：\(ProfileStore.dir.path)）")
        exit(4)
    }
    guard let cred = loadCredential(for: sel.id) else {
        printErr("钥匙串里没有「\(sel.profile.name)」的凭据")
        exit(3)
    }
    let vpn = (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/Applications/VPNMenu.app"))
        .appendingPathComponent("vpn").path
    let (code, out) = runWithInput("/usr/bin/sudo", ["-n", vpn + "/zc-vpn-on"],
                                   connectionPayload(sel.profile, cred))
    print(out, terminator: "")
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
