// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

// MARK: - 账号（钥匙串）

extension AppDelegate {
    @objc func setAccount() {
        guard let sel = selectedProfile() else {
            alert("还没有配置", "请先在「配置 → 导入配置…」里导入一份配置，再录入账号。")
            return
        }
        _ = promptCredential(for: sel)
    }

    /// 弹出录入框，保存到登录钥匙串。返回是否保存成功。
    @discardableResult
    func promptCredential(for sel: (id: String, profile: Profile)) -> Bool {
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
}
