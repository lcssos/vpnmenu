// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

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
