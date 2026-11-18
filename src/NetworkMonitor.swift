// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network
import SystemConfiguration

/// 当前物理网络的身份：主网卡名 + 它的 IPv4 + 默认路由。
///
/// 只看「默认路由所走的那块网卡」，而不是所有网卡：插拔 iPhone USB、Thunderbolt
/// 桥接等其它接口变化时不该触发重连。VPN 的 `utun` 不做默认路由（分流模式），
/// 也不会被误认为物理网络；如果它真的成了主接口，本函数返回空串，表示“物理
/// 网络不可判定”，调用方不会据此重连。
enum NetworkSignature {
    private static let store = SCDynamicStoreCreate(
        nil, "VPNMenu" as CFString, nil, nil)

    static func current() -> String {
        guard let store,
              let value = SCDynamicStoreCopyValue(
                store, "State:/Network/Global/IPv4" as CFString),
              let dict = value as? [String: Any],
              let primary = dict["PrimaryInterface"] as? String,
              !primary.isEmpty, !primary.hasPrefix("utun"),
              let ip = ipv4(of: primary) else { return "" }
        let router = dict["Router"] as? String ?? "-"
        return "\(primary)=\(ip)|\(router)"
    }

    private static func ipv4(of name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }
            guard String(cString: cur.pointee.ifa_name) == name,
                  let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { return nil }
            let ip = String(cString: host)
            // 网卡可能有多个地址（别名）；链路本地地址不代表可用网络，跳过
            if ip.hasPrefix("169.254.") { continue }
            return ip
        }
        return nil
    }
}

/// 监听物理网络变化：NWPathMonitor 负责事件（含断网/恢复），`checkNow()` 在每次
/// 状态刷新时兜底比对（部分 Wi-Fi 漫游到另一个 Wi-Fi 不会产生 path 事件）。
/// 所有状态都在串行队列上访问；`onChange` 回到主线程。
final class NetworkMonitor {
    private let queue = DispatchQueue(label: "com.lcssos.vpnmenu.network")
    private let pathMonitor = NWPathMonitor()
    private var detector = NetworkChangeDetector(settle: 3.0)
    private var lastSatisfied = true
    private var settleWork: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.sync {
            _ = detector.update(signature: NetworkSignature.current(), satisfied: true)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lastSatisfied = path.status == .satisfied
            self.handle(satisfied: self.lastSatisfied)
        }
        pathMonitor.start(queue: queue)
    }

    /// 由状态刷新调用；没有变化时只做一次 getifaddrs，很便宜。
    func checkNow() {
        queue.async { [weak self] in
            guard let self else { return }
            self.handle(satisfied: self.lastSatisfied)
        }
    }

    func stop() {
        pathMonitor.cancel()
        settleWork?.cancel()
        settleWork = nil
    }

    private func handle(satisfied: Bool) {
        let fired = detector.update(signature: NetworkSignature.current(),
                                    satisfied: satisfied, now: Date())
        if fired {
            DispatchQueue.main.async { [weak self] in self?.onChange() }
            return
        }
        if detector.hasPending { scheduleSettle() }
    }

    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let fired = self.detector.update(signature: NetworkSignature.current(),
                                             satisfied: self.lastSatisfied, now: Date())
            if fired {
                DispatchQueue.main.async { [weak self] in self?.onChange() }
            } else if self.detector.hasPending {
                self.scheduleSettle()
            }
        }
        settleWork = work
        queue.asyncAfter(deadline: .now() + detector.settle, execute: work)
    }

    deinit {
        pathMonitor.cancel()
        settleWork?.cancel()
    }
}
