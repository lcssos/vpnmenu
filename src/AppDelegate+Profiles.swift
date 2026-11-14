// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

// MARK: - 配置菜单

extension AppDelegate {
    /// 每 2 秒的刷新会调用这里，但只有「目录 mtime 变了 / 第一次扫描 / 距上次扫描
    /// 超过 60 秒 / 显式 force」时才真正读盘并解码 JSON，避免每 2 秒全量解析配置。
    func reloadProfiles(force: Bool = false) {
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

    func selectedProfile() -> (id: String, profile: Profile)? {
        if profiles.isEmpty { reloadProfiles(force: true) }
        if let id = selectedID, let hit = profiles.first(where: { $0.id == id }) {
            return hit
        }
        return profiles.first
    }

    @objc func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != selectedID else { return }
        guard let target = profiles.first(where: { $0.id == id }) else { return }

        let connected = monitor.alivePID() != nil
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
            _ = run("/usr/bin/sudo", ["-n", VPMPaths.off])
            DispatchQueue.main.async {
                self.finishBusy()
                self.connect()
            }
        }
    }

    // MARK: - 导入 / 导出 / 删除

    @objc func importProfileAction() {
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
        let connected = monitor.alivePID() != nil
        if connected {
            // 不悄悄切走正在使用的配置；断开后再让用户选择
            alert("导入成功", "配置「\(name)」已导入。当前连接仍使用原配置；断开后可在「配置」里切换。")
        } else {
            UserDefaults.standard.set(id, forKey: ProfileStore.selectedKey)
        }
        reloadProfiles(force: true)
        refresh()
    }

    @objc func exportProfileAction() {
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

    @objc func deleteProfileAction() {
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

    @objc func openProfilesDir() {
        ProfileStore.ensureDir()
        NSWorkspace.shared.open(ProfileStore.dir)
    }
}
