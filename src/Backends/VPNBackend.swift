import Darwin
import Foundation

typealias Credential = (user: String, pass: String)

struct BackendStatus {
    let pid: pid_t?
    let alive: Bool
    let ready: Bool
    var connected: Bool { alive && ready }
}

/// 一个 VPN 后端需要提供的能力。只覆盖「用户名密码 + TUN」这一类。
///
/// 线程约定：`status()`、`alivePID()`、`repairStaleStateIfNeeded` 仅主线程调用
/// （状态缓存不加锁）；`processPresent()`、`readyVerified()` 可在任意线程调用。
protocol VPNBackend: AnyObject {
    var id: String { get }
    var displayName: String { get }

    /// 本后端特有字段的校验；通用字段由 ProfileValidation.commonError 负责。
    func validate(_ p: Profile) -> String?

    var installScript: String { get }
    var installDir: String { get }
    var sudoersPath: String { get }
    func needsInstall(output: String) -> Bool

    func payload(_ p: Profile, _ c: Credential) -> String
    var connectScript: String { get }
    var disconnectScript: String { get }

    func status() -> BackendStatus
    func alivePID() -> pid_t?
    func processPresent() -> Bool
    func readyVerified() -> Bool
    func repairStaleStateIfNeeded(busy: Bool)

    var logFile: String { get }
}

enum BackendRegistry {
    static var all: [VPNBackend] = [ZjuConnectBackend.shared]

    static func backend(id: String, in list: [VPNBackend] = all) -> VPNBackend? {
        list.first { $0.id == id }
    }

    static func backend(for p: Profile, in list: [VPNBackend] = all) -> VPNBackend? {
        backend(id: p.backendID, in: list)
    }

    /// 第一个存活后端的完整状态；仅主线程调用。
    static func live(in list: [VPNBackend] = all) -> (backend: VPNBackend, status: BackendStatus)? {
        for b in list {
            let s = b.status()
            if s.alive { return (b, s) }
        }
        return nil
    }

    static func anyActiveProcess(in list: [VPNBackend] = all) -> Bool {
        list.contains { $0.processPresent() }
    }

    /// 实际在跑的隧道（只看进程是否存在，不做命令行校验）；任意线程调用。
    /// 用于决定断开/退出目标：宁可多停一次，也不要停错后端。
    static func running(in list: [VPNBackend] = all) -> VPNBackend? {
        list.first { $0.processPresent() }
    }

    /// 纯选择逻辑：存活 > 连接在飞 > 选中配置 > 第一个注册后端。
    static func resolve(alive: VPNBackend?, pending: VPNBackend?,
                        selected: VPNBackend?, registered: [VPNBackend]) -> VPNBackend? {
        alive ?? pending ?? selected ?? registered.first
    }

    /// 没有后端存活且空闲时，让每个后端修复自己的残留状态（zju 是 DNS 兜底）。
    static func repairStaleStatesIfIdle(busy: Bool, in list: [VPNBackend] = all) {
        guard !busy, live(in: list) == nil else { return }
        for b in list { b.repairStaleStateIfNeeded(busy: false) }
    }

    static func validate(_ p: Profile, in list: [VPNBackend] = all) -> String? {
        if let e = ProfileValidation.commonError(for: p) { return e }
        guard let b = backend(for: p, in: list) else {
            return "不支持的 VPN 类型：\(p.backendID)"
        }
        return b.validate(p)
    }
}
