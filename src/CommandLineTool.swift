// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - 命令行辅助模式（不启动菜单栏）

private func printErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// 处理 `--import-profile` / `--list-profiles` / `--set-credential` / `--vpn-on`。
/// 命中时执行后直接 exit，不会启动菜单栏。
func runCommandLineToolIfRequested() {
    let cliArgs = CommandLine.arguments

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
        guard let backend = BackendRegistry.backend(for: sel.profile) else {
            printErr("不支持的 VPN 类型：\(sel.profile.backendID)")
            exit(4)
        }
        let (code, out) = runWithInput("/usr/bin/sudo", ["-n", backend.connectScript],
                                       backend.payload(sel.profile, cred))
        print(out, terminator: "")
        exit(code)
    }
}
