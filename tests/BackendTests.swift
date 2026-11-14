import Foundation

final class FakeBackend: VPNBackend {
    let id: String
    var displayName: String { "fake-\(id)" }
    var statusResult = BackendStatus(pid: nil, alive: false, ready: false)
    var present = false
    var repairCalls = 0
    var validateError: String?
    var installScript = ""; var installDir = ""; var sudoersPath = ""
    var connectScript = ""; var disconnectScript = ""; var logFile = ""
    init(id: String) { self.id = id }
    func validate(_ p: Profile) -> String? { validateError }
    func needsInstall(output: String) -> Bool { false }
    func payload(_ p: Profile, _ c: Credential) -> String { "" }
    func status() -> BackendStatus { statusResult }
    func alivePID() -> pid_t? { statusResult.pid }
    func processPresent() -> Bool { present }
    func readyVerified() -> Bool { statusResult.ready }
    func repairStaleStateIfNeeded(busy: Bool) { repairCalls += 1 }
}

func runBackendTests() {
    let a = FakeBackend(id: "a"), b = FakeBackend(id: "b")

    check(BackendRegistry.resolve(alive: nil, pending: a, selected: b, registered: [a, b]) === a,
          "连接在飞时以 pending 为准")
    check(BackendRegistry.resolve(alive: b, pending: a, selected: a, registered: [a, b]) === b,
          "有存活隧道时以存活为准")
    check(BackendRegistry.resolve(alive: nil, pending: nil, selected: nil, registered: [a, b]) === a,
          "全空时兜底到第一个后端")

    var p = makeProfile(name: "x", server: "vpn.example.com"); p.backend = "nope"
    checkEqual(BackendRegistry.validate(p, in: [a]), "不支持的 VPN 类型：nope", "未知后端报错")

    a.statusResult = BackendStatus(pid: nil, alive: false, ready: false)
    BackendRegistry.repairStaleStatesIfIdle(busy: false, in: [a, b])
    checkEqual(a.repairCalls, 1, "无存活且空闲时修复")
    checkEqual(b.repairCalls, 1, "遍历所有后端")
    BackendRegistry.repairStaleStatesIfIdle(busy: true, in: [a, b])
    checkEqual(a.repairCalls, 1, "busy 时不修复")
}
