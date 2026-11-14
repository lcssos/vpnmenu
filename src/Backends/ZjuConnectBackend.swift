import Darwin
import Foundation

/// zju-connect（EasyConnect 协议）+ TUN 的实现。路径、脚本参数、DNS 兜底都收在这里。
final class ZjuConnectBackend: VPNBackend {
    static let shared = ZjuConnectBackend()

    let id = BackendID.zjuConnect
    let displayName = "zju-connect"

    static let pidFile = "/var/run/zju-connect.pid"
    static let readyFile = "/var/run/zju-connect.ready"

    /// 所有组件都在 App 内部：Contents/Resources/vpn/
    static let vpnDir: String = {
        if let res = Bundle.main.resourceURL {
            return res.appendingPathComponent("vpn").path
        }
        return "/Applications/VPNMenu.app/Contents/Resources/vpn"
    }()

    private let probe = ProcessFileProbe(config: .init(
        pidFile: ZjuConnectBackend.pidFile,
        readyFile: ZjuConnectBackend.readyFile,
        commandMarker: ZjuConnectBackend.vpnDir + "/zc-tun.sh"))

    private var lastDNSRepair = Date.distantPast

    var installScript: String { Self.vpnDir + "/install.sh" }
    var installDir: String { Self.vpnDir }
    var sudoersPath: String { "/etc/sudoers.d/vpnmenu" }
    var connectScript: String { Self.vpnDir + "/zc-vpn-on" }
    var disconnectScript: String { Self.vpnDir + "/zc-vpn-off" }
    var logFile: String { NSHomeDirectory() + "/Library/Logs/VPNMenu/zju-connect.log" }

    func validate(_ p: Profile) -> String? {
        ProfileValidation.zjuError(for: p)
    }

    func needsInstall(output: String) -> Bool {
        if !FileManager.default.fileExists(atPath: sudoersPath) { return true }
        let t = output.lowercased()
        return t.contains("password is required") || t.contains("terminal is required")
    }

    /// 通过 stdin 交给 root 脚本的 key=value 协议；脚本只做白名单解析，绝不 source 配置文件。
    func payload(_ p: Profile, _ c: Credential) -> String {
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

    func status() -> BackendStatus {
        let pid = alivePID()
        return BackendStatus(pid: pid,
                             alive: pid != nil,
                             ready: pid.map { probe.tunnelReady($0) } ?? false)
    }

    func alivePID() -> pid_t? { probe.alivePID() }
    func processPresent() -> Bool { probe.processPresent() }
    func readyVerified() -> Bool { probe.readyVerified() }

    /// zju-connect panic 时可能把系统 DNS 留在 2.0.1.x（隧道已死、不可达）。
    /// 调用方负责确认当前没有操作在进行。
    func repairStaleStateIfNeeded(busy: Bool) {
        guard !busy, probe.alivePID() == nil, hasStaleDNS() else { return }
        guard Date().timeIntervalSince(lastDNSRepair) > 30 else { return }
        lastDNSRepair = Date()
        DispatchQueue.global().async { [disconnectScript] in
            _ = run("/usr/bin/sudo", ["-n", disconnectScript])
        }
    }

    private func hasStaleDNS() -> Bool {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return false
        }
        // (?m) 多行模式：只匹配行首的 nameserver
        return text.range(of: #"(?m)^nameserver[ \t]+2\.0\.1\.[0-9]+"#,
                          options: .regularExpression) != nil
    }
}
