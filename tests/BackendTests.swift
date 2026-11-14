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

    a.present = true; b.present = false
    check(BackendRegistry.running(in: [b, a]) === a, "以 processPresent 识别运行中的后端")

    let legacyProfile = makeProfile(name: "old", server: "vpn.example.com")
    checkEqual(BackendRegistry.validate(legacyProfile), nil, "旧配置通过注册表校验")
    checkEqual(BackendRegistry.backend(for: legacyProfile)?.id, "zju-connect",
               "旧配置解析到 zju 后端")

    a.present = false
    a.statusResult = BackendStatus(pid: nil, alive: false, ready: false)
    BackendRegistry.repairStaleStatesIfIdle(busy: false, in: [a, b])
    checkEqual(a.repairCalls, 1, "无存活且空闲时修复")
    checkEqual(b.repairCalls, 1, "遍历所有后端")
    BackendRegistry.repairStaleStatesIfIdle(busy: true, in: [a, b])
    checkEqual(a.repairCalls, 1, "busy 时不修复")

    runZjuBackendTests()
}

func runZjuBackendTests() {
    let dir = NSTemporaryDirectory() + "vpnmenu-tests-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let pidFile = dir + "/pid", readyFile = dir + "/ready"
    let me = getpid()
    try! "\(me)\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
    try! "\(me) 99999\n".write(toFile: readyFile, atomically: true, encoding: .utf8)

    let probe = ProcessFileProbe(config: .init(
        pidFile: pidFile, readyFile: readyFile,
        commandMarker: CommandLine.arguments[0]))
    checkEqual(probe.alivePID(), me, "探针识别存活进程")
    check(probe.tunnelReady(me), "探针识别就绪标记")
    checkEqual(probe.alivePID(), me, "缓存命中仍返回 PID")

    let zju = ZjuConnectBackend.shared
    checkEqual(zju.id, "zju-connect", "后端 id")
    check(zju.connectScript.hasSuffix("/zc-vpn-on"), "连接脚本路径")
    check(zju.disconnectScript.hasSuffix("/zc-vpn-off"), "断开脚本路径")
    check(zju.logFile.hasSuffix("/Library/Logs/VPNMenu/zju-connect.log"), "日志路径")

    var p = makeProfile(name: "n", server: "vpn.example.com")
    p.tunInterface = "en0"
    checkEqual(zju.validate(p), "隧道接口名不合法：en0", "zju 校验 tun")

    p.tunInterface = "utun9"; p.socksBind = "127.0.0.1:2090"
    p.httpBind = "127.0.0.1:2091"; p.domains = ["a.example.com"]
    p.proxyDomains = ["b.example.com"]
    let expected = [
        "ACCOUNT=user", "PASSWORD=pass", "SERVER=vpn.example.com", "PORT=4430",
        "TUN_IF=utun9", "SOCKS_BIND=127.0.0.1:2090", "HTTP_BIND=127.0.0.1:2091",
        "DOMAIN=a.example.com", "PROXY_DOMAIN=b.example.com",
    ].joined(separator: "\n") + "\n"
    checkEqual(zju.payload(p, ("user", "pass")), expected, "连接参数 payload 不变")

    check(BackendRegistry.all.contains { $0.id == "zju-connect" }, "注册表包含 zju")
}
