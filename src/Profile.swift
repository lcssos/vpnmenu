// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - 本机配置（不进仓库、也不进 App 包）

/// 后端标识。新增后端时在 BackendRegistry 注册同名 id。
enum BackendID {
    static let zjuConnect = "zju-connect"
}

/// 连接参数只保存在本机：~/Library/Application Support/VPNMenu/profiles/<uuid>.json
/// 账号密码不在这里，见 Keychain.swift。
struct Profile: Codable {
    var schema: Int?
    /// 缺省（旧配置）视为 zju-connect；导出时不写 null。
    var backend: String?
    var name: String
    var server: String
    var port: Int?
    var tunInterface: String?
    var socksBind: String?
    var httpBind: String?
    var domains: [String]?
    var proxyDomains: [String]?
    /// 系统 DNS 由谁实现：`script`（默认，zc-tun.sh 只改有 IP 的服务）或
    /// `zju`（zju-connect 的 -dns-hijack，启动时串行改所有服务）。
    var dnsMode: String?
    /// 多线路选线由谁实现：`script`（默认，直接用配置的 server）或
    /// `zju`（zju-connect 登录后 ping 各线路选最优）。
    var multiLine: String?

    var backendID: String { backend ?? BackendID.zjuConnect }
    var portValue: Int { port ?? 4430 }
    var domainList: [String] { domains ?? [] }
    var proxyDomainList: [String] { proxyDomains ?? [] }
    var dnsModeValue: String {
        let v = dnsMode ?? ""
        return v.isEmpty ? "script" : v
    }
    var multiLineValue: String {
        let v = multiLine ?? ""
        return v.isEmpty ? "script" : v
    }

    private enum CodingKeys: String, CodingKey {
        case schema, backend, name, server, port
        case tunInterface, socksBind, httpBind, domains, proxyDomains
        case dnsMode, multiLine
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(schema, forKey: .schema)
        try c.encodeIfPresent(backend, forKey: .backend)
        try c.encode(name, forKey: .name)
        try c.encode(server, forKey: .server)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(tunInterface, forKey: .tunInterface)
        try c.encodeIfPresent(socksBind, forKey: .socksBind)
        try c.encodeIfPresent(httpBind, forKey: .httpBind)
        try c.encodeIfPresent(domains, forKey: .domains)
        try c.encodeIfPresent(proxyDomains, forKey: .proxyDomains)
        try c.encodeIfPresent(dnsMode, forKey: .dnsMode)
        try c.encodeIfPresent(multiLine, forKey: .multiLine)
    }
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

    /// 与后端无关的通用校验。返回 nil 表示合法。
    static func commonError(for p: Profile) -> String? {
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "配置名称不能为空" }
        if name.count > 80 { return "配置名称过长" }
        if !isHost(p.server) { return "服务器地址不合法：\(p.server)" }
        let port = p.portValue
        if port < 1 || port > 65535 { return "端口不合法：\(port)" }
        return nil
    }

    /// zju-connect 特有的字段校验。返回 nil 表示合法。
    static func zjuError(for p: Profile) -> String? {
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
        if let v = p.dnsMode, !v.isEmpty, v != "script", v != "zju" {
            return "DNS 模式不合法：\(v)（可选 script / zju）"
        }
        if let v = p.multiLine, !v.isEmpty, v != "script", v != "zju" {
            return "选线模式不合法：\(v)（可选 script / zju）"
        }
        return nil
    }

    /// 完整校验（过渡期保留；接入注册表后由 BackendRegistry.validate 统一调用）。
    static func error(for p: Profile) -> String? {
        commonError(for: p) ?? zjuError(for: p)
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
                  BackendRegistry.validate(p) == nil else { continue }
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
        if let err = BackendRegistry.validate(p) { return (nil, err) }
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
