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
