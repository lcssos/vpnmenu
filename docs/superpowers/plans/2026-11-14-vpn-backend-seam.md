# VPNMenu 最小后端接口 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 zju-connect 专有知识收进一个 `VPNBackend` 实现，使新增「用户名密码 + TUN」类后端只需新增实现与资源，不改 UI 与状态机。

**Architecture:** 新增 `src/Backends/`：协议 + 注册表 + 通用 pidfile/ready 探针 + zju 实现。现有 `AppDelegate` 及其扩展改为通过 `currentTunnelBackend()` 调用。旧配置、安装路径、bundle 布局保持不变。

**Tech Stack:** Swift 5、Cocoa/Foundation、bash 3.2、swiftc 手工构建。

**Spec:** `docs/superpowers/specs/2026-11-14-vpn-backend-seam-design.md`

## Global Constraints

- 界面文案只用中文，不做国际化。
- 旧配置 JSON（无 `backend` 字段）必须照常解码、显示、连接；缺省后端为 `zju-connect`。
- bundle 内路径 `Contents/Resources/vpn/`、`/var/run/zju-connect.*`、sudoers 路径不得改变；已安装用户不重装。
- `tools/build.sh` 必须兼容 macOS 自带 bash 3.2，不使用 `mapfile`。
- 状态探针线程约定：`status()` / `alivePID()` / `repairStaleStateIfNeeded` 仅主线程；`processPresent()` / `readyVerified()` 任意线程。
- 不引入第三方依赖，不新增 Xcode 工程。
- 每个提交信息以 `Co-Authored-By: Claude Code <noreply@anthropic.com>` 结尾。

## Review Focus

- 旧配置 JSON 无 `backend` → 必须正常出现在配置菜单并可连接（Task 2 的解码/编码测试）。
- 连接 A 后立刻把选中项切到 B、A 的 pidfile 尚未出现 → 断开/退出必须停 A 而不是 B（Task 3 的 `resolve` 测试）。
- 零配置、无选中项 → 打开日志、重新安装仍指向 zju-connect（Task 3 的 fallback 测试）。
- 连接命令在飞时退出 App → 必须调用 `zc-vpn-off`（Task 6，人工回归）。
- zju panic 后删掉配置或选中别的后端 → `2.0.1.x` 残留 DNS 仍被修复（Task 3 的注册表遍历测试）。

---

### Task 1: 测试脚手架与现有行为基线

**Files:**
- Create: `tools/test.sh`
- Create: `tests/main.swift`
- Create: `tests/ProfileTests.swift`

**Interfaces:**
- Consumes: `Profile`、`ProfileStore.encode`、`ProfileValidation.error(for:)`（现有实现）
- Produces: `tools/test.sh` 运行 `build/vpnmenu-tests`；测试辅助 `check(_:_:)`、`checkEqual(_:_:_:)`、`runProfileTests()`

- [ ] **Step 1: 写基线测试（characterization，不改产品代码）**

`tests/main.swift`：

```swift
import Foundation

var failures = 0

func check(_ cond: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond { print("ok   \(name)") }
    else { failures += 1; print("FAIL \(name)  (\(file):\(line))") }
}

func checkEqual<T: Equatable>(_ got: T, _ want: T, _ name: String,
                              file: String = #file, line: Int = #line) {
    check(got == want, "\(name) (got \(got), want \(want))", file: file, line: line)
}

/// 测试用：构造只带必填字段的 Profile（避免依赖 memberwise init 的可选参数列表）。
func makeProfile(name: String, server: String) -> Profile {
    let json = #"{"name":"\#(name)","server":"\#(server)"}"#
    return try! JSONDecoder().decode(Profile.self, from: Data(json.utf8))
}

runProfileTests()
exit(failures == 0 ? 0 : 1)
```

`tests/ProfileTests.swift`：

```swift
import Foundation

private func decode(_ json: String) -> Profile? {
    try? JSONDecoder().decode(Profile.self, from: Data(json.utf8))
}

func runProfileTests() {
    let legacy = decode(#"{"name":"公司 VPN","server":"vpn.example.com"}"#)
    check(legacy != nil, "旧配置可解码")
    checkEqual(legacy?.portValue, 4430, "默认端口 4430")
    checkEqual(legacy?.domainList.count, 0, "默认无域名")
    checkEqual(ProfileValidation.error(for: legacy!), nil, "旧配置通过校验")

    var badTun = legacy!; badTun.tunInterface = "en0"
    checkEqual(ProfileValidation.error(for: badTun), "隧道接口名不合法：en0", "非法 tun 被拒")

    let encoded = String(data: ProfileStore.encode(legacy!)!, encoding: .utf8)!
    let back = try? JSONDecoder().decode(Profile.self, from: Data(encoded.utf8))
    checkEqual(back?.server, "vpn.example.com", "编码往返保留字段")
}
```

- [ ] **Step 2: 写测试脚本**

`tools/test.sh`：

```bash
#!/bin/bash
# Copyright (C) 2026 lcssos
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 -o "$ROOT/build/vpnmenu-tests" \
  "$ROOT"/tests/*.swift \
  "$ROOT"/src/Profile.swift \
  "$ROOT"/src/Process.swift
"$ROOT/build/vpnmenu-tests"
```

- [ ] **Step 3: 运行基线测试**

Run: `chmod +x tools/test.sh && tools/test.sh`
Expected: 全部 `ok`，退出码 0。

- [ ] **Step 4: 提交**

```bash
git add tools/test.sh tests/TestMain.swift tests/ProfileTests.swift
git commit -m "test: 增加纯逻辑测试脚手架与 Profile 基线用例

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: Profile 增加 backend 字段并拆分校验

**Files:**
- Modify: `src/Profile.swift`
- Test: `tests/ProfileTests.swift`

**Interfaces:**
- Consumes: 现有 `Profile`、`ProfileValidation`
- Produces:
  - `enum BackendID { static let zjuConnect = "zju-connect" }`
  - `Profile.backend: String?`、`Profile.backendID: String`
  - `ProfileValidation.commonError(for:) -> String?`
  - `ProfileValidation.zjuError(for:) -> String?`
  - `ProfileValidation.error(for:)` 行为不变（`commonError ?? zjuError`）

- [ ] **Step 1: 先写失败测试**

在 `runProfileTests()` 末尾追加：

```swift
    checkEqual(legacy?.backendID, "zju-connect", "缺省后端为 zju-connect")

    var other = legacy!; other.backend = "other"
    checkEqual(other.backendID, "other", "显式后端生效")

    let legacyJSON = String(data: ProfileStore.encode(legacy!)!, encoding: .utf8)!
    check(!legacyJSON.contains("\"backend\""), "backend 为 nil 时不写入 JSON")

    let otherJSON = String(data: ProfileStore.encode(other)!, encoding: .utf8)!
    check(otherJSON.contains("\"backend\" : \"other\""), "显式 backend 写入 JSON")

    var badName = legacy!; badName.name = ""
    checkEqual(ProfileValidation.commonError(for: badName), "配置名称不能为空", "通用校验：名称")
    checkEqual(ProfileValidation.zjuError(for: badTun), "隧道接口名不合法：en0", "后端校验：tun")
```

- [ ] **Step 2: 运行测试确认失败**

Run: `tools/test.sh`
Expected: 编译失败，`value of type 'Profile' has no member 'backendID'`。

- [ ] **Step 3: 实现**

`src/Profile.swift` 增加：

```swift
enum BackendID {
    static let zjuConnect = "zju-connect"
}

struct Profile: Codable {
    var schema: Int?
    var backend: String?
    var name: String
    var server: String
    var port: Int?
    var tunInterface: String?
    var socksBind: String?
    var httpBind: String?
    var domains: [String]?
    var proxyDomains: [String]?

    var backendID: String { backend ?? BackendID.zjuConnect }
    // 其余计算属性不变

    private enum CodingKeys: String, CodingKey {
        case schema, backend, name, server, port
        case tunInterface, socksBind, httpBind, domains, proxyDomains
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
    }
}
```

校验拆分：把现有 `error(for:)` 中的名称/服务器/端口移入 `commonError`，其余移入 `zjuError`；`error(for:)` 改成 `commonError(for:) ?? zjuError(for:)`。错误文案逐字保留。

- [ ] **Step 4: 运行测试**

Run: `tools/test.sh`
Expected: 全部 `ok`。

- [ ] **Step 5: 提交**

```bash
git add src/Profile.swift tests/ProfileTests.swift
git commit -m "feat(profile): 增加可选 backend 字段并拆分通用/后端校验

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: 后端协议、状态结构、注册表与选择规则

**Files:**
- Create: `src/Backends/VPNBackend.swift`
- Create: `tests/BackendTests.swift`
- Modify: `tests/main.swift`（调用 `runBackendTests()`）
- Modify: `tools/test.sh`（加入 `src/Backends/*.swift`）

**Interfaces:**
- Consumes: `Profile`、`ProfileValidation.commonError`、`Credential` 不在此任务产生
- Produces:
  - `typealias Credential = (user: String, pass: String)`
  - `struct BackendStatus { let pid: pid_t?; let alive: Bool; let ready: Bool; var connected: Bool }`
  - `protocol VPNBackend: AnyObject`（完整方法见 Step 3）
  - `enum BackendRegistry`
    - `static var all: [VPNBackend]`（本任务暂为空）
    - `backend(id:in:)`、`backend(for:in:)`、`live(in:)`、`anyActiveProcess(in:)`
    - `resolve(alive:pending:selected:registered:)`
    - `repairStaleStatesIfIdle(busy:in:)`
    - `validate(_:in:)`
  - 测试用 `FakeBackend`

- [ ] **Step 1: 写失败测试**

`tests/BackendTests.swift`：

```swift
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
```

`tests/main.swift` 在 `runProfileTests()` 后加 `runBackendTests()`。

- [ ] **Step 2: 运行确认失败**

Run: `tools/test.sh`（先在脚本源码列表加入 `"$ROOT"/src/Backends/VPNBackend.swift` 与 `"$ROOT"/tests/BackendTests.swift` 的 glob `"$ROOT"/src/Backends/*.swift`）
Expected: 编译失败，找不到 `VPNBackend` / `BackendRegistry`。

- [ ] **Step 3: 实现 `src/Backends/VPNBackend.swift`**

```swift
import Darwin
import Foundation

typealias Credential = (user: String, pass: String)

struct BackendStatus {
    let pid: pid_t?
    let alive: Bool
    let ready: Bool
    var connected: Bool { alive && ready }
}

protocol VPNBackend: AnyObject {
    var id: String { get }
    var displayName: String { get }

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
    /// Task 4 注册 ZjuConnectBackend 后替换为 [ZjuConnectBackend.shared]。
    static var all: [VPNBackend] = []

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

    /// 纯选择逻辑：存活 > 连接在飞 > 选中配置 > 第一个注册后端。
    static func resolve(alive: VPNBackend?, pending: VPNBackend?,
                        selected: VPNBackend?, registered: [VPNBackend]) -> VPNBackend? {
        alive ?? pending ?? selected ?? registered.first
    }

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
```

- [ ] **Step 4: 运行测试**

Run: `tools/test.sh`
Expected: 全部 `ok`。

- [ ] **Step 5: 提交**

```bash
git add src/Backends/VPNBackend.swift tests/BackendTests.swift tests/TestMain.swift tools/test.sh
git commit -m "feat(backend): 增加最小后端协议、注册表与选择规则

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: 通用状态探针与 zju-connect 实现

**Files:**
- Create: `src/Backends/ProcessFileProbe.swift`
- Create: `src/Backends/ZjuConnectBackend.swift`
- Modify: `src/Backends/VPNBackend.swift`（`all = [ZjuConnectBackend.shared]`）
- Modify: `src/Profile.swift`（`ProfileStore.list` / `importProfile` 改走 `BackendRegistry.validate`）
- Modify: `tests/BackendTests.swift`
- Modify: `tools/test.sh`（源码已是 `src/Backends/*.swift`，无需再改）

**Interfaces:**
- Consumes: `VPNBackend`、`BackendRegistry`、`ProfileValidation.zjuError`、`run`
- Produces:
  - `final class ProcessFileProbe`：`init(config:)`、`currentPID()`、`alivePID()`、`tunnelReady(_:)`、`processPresent()`、`readyVerified()`
  - `final class ZjuConnectBackend: VPNBackend`，`static let shared`
  - `BackendRegistry.all == [ZjuConnectBackend.shared]`

- [ ] **Step 1: 先写失败测试**

在 `tests/BackendTests.swift` 追加：

```swift
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
```

`runBackendTests()` 末尾调用 `runZjuBackendTests()`。

- [ ] **Step 2: 运行确认失败**

Run: `tools/test.sh`
Expected: 编译失败，找不到 `ProcessFileProbe`。

- [ ] **Step 3: 实现 `ProcessFileProbe`**

把 `src/VPNMonitor.swift` 的 `currentPID`、`processExists`、`processStartTime`、`alivePID`、`tunnelReady`、`processPresent`、`readyVerified` 原样搬入，`VPMPaths.statusPidFile` / `VPMPaths.readyFile` / `VPMPaths.vpnDir + "/zc-tun.sh"` 替换为 `config.pidFile` / `config.readyFile` / `config.commandMarker`。**不要**搬入 DNS 逻辑。

- [ ] **Step 4: 实现 `ZjuConnectBackend`**

- 路径：`vpnDir` 逻辑照抄 `VPMPaths.vpnDir`；`connectScript = vpnDir + "/zc-vpn-on"`，`disconnectScript = vpnDir + "/zc-vpn-off"`，`installScript = vpnDir + "/install.sh"`，`installDir = vpnDir`，`sudoersPath = "/etc/sudoers.d/vpnmenu"`，`logFile = NSHomeDirectory() + "/Library/Logs/VPNMenu/zju-connect.log"`
- probe 配置：`pidFile = "/var/run/zju-connect.pid"`、`readyFile = "/var/run/zju-connect.ready"`、`commandMarker = vpnDir + "/zc-tun.sh"`
- `validate` 直接返回 `ProfileValidation.zjuError(for:)`
- `needsInstall`、`payload` 从 `AppDelegate+Install` / `Keychain.connectionPayload` 原样搬入
- `status`：`let pid = alivePID(); return .init(pid: pid, alive: pid != nil, ready: pid.map { probe.tunnelReady($0) } ?? false)`
- `repairStaleStateIfNeeded(busy:)`：`guard !busy, !probe.processPresent(), hasStaleDNS() else { return }`，再执行原 30 秒节流 + `sudo -n zc-vpn-off`
- 在 `VPNBackend.swift` 把 `all` 改为 `[ZjuConnectBackend.shared]`
- `ProfileStore.list()` 与 `importProfile` 改用 `BackendRegistry.validate(_:)`

- [ ] **Step 5: 运行测试**

Run: `tools/test.sh`
Expected: 全部 `ok`。

- [ ] **Step 6: 提交**

```bash
git add src/Backends src/Profile.swift tests/BackendTests.swift
git commit -m "feat(backend): 抽取通用状态探针并实现 zju-connect 后端

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: 状态显示与菜单接入后端

**Files:**
- Modify: `src/AppDelegate.swift`
- Modify: `src/AppDelegate+MenuBar.swift`
- Modify: `src/AppDelegate+Profiles.swift`（仅两处 `monitor.alivePID()`）

**Interfaces:**
- Consumes: `BackendRegistry.live()`、`resolve`、`repairStaleStatesIfIdle`
- Produces（`AppDelegate` 新增）:
  - `var tunnelBackend: VPNBackend?`
  - `func selectedBackend() -> VPNBackend?`
  - `func currentTunnelBackend() -> VPNBackend`（`registered` 非空，强制解包安全）
  - `func isConnected() -> Bool`（`BackendRegistry.live() != nil`）

- [ ] **Step 1: 实现状态接入**

`AppDelegate.refresh()` 改为：

```swift
reloadProfiles()
let live = BackendRegistry.live()
let processAlive = live != nil
let connected = live?.status.ready ?? false
if !processAlive { BackendRegistry.repairStaleStatesIfIdle(busy: busy) }
if !processAlive && !busy && !waitingReady { tunnelBackend = nil }
```

其余菜单 enable 与文案分支保持原样。**本任务保留** `let monitor = VPNMonitor()`：连接/安装/退出路径仍在用它，等 Task 6 全部迁移后再删除。

新增辅助方法：

```swift
func selectedBackend() -> VPNBackend? {
    guard let id = selectedID,
          let hit = profiles.first(where: { $0.id == id }) else { return nil }
    return BackendRegistry.backend(for: hit.profile)
}

func currentTunnelBackend() -> VPNBackend {
    BackendRegistry.resolve(alive: BackendRegistry.live()?.backend,
                            pending: tunnelBackend,
                            selected: selectedBackend(),
                            registered: BackendRegistry.all)!
}

func isConnected() -> Bool { BackendRegistry.live() != nil }
```

`AppDelegate+MenuBar.swift`：`let connectedNow = monitor.alivePID() != nil` → `let connectedNow = isConnected()`。
`AppDelegate+Profiles.swift` 两处 `let connected = monitor.alivePID() != nil` → `let connected = isConnected()`。

- [ ] **Step 2: 验证编译（此时连接路径仍引用旧 monitor，允许存在）**

Run: `swiftc -typecheck -swift-version 5 -target arm64-apple-macos11.0 -framework Cocoa -framework Security $(find src -name '*.swift' | sort)`
Expected: 通过。

- [ ] **Step 3: 运行测试**

Run: `tools/test.sh`
Expected: 全部 `ok`。

- [ ] **Step 4: 提交**

```bash
git add src/AppDelegate.swift src/AppDelegate+MenuBar.swift src/AppDelegate+Profiles.swift
git commit -m "refactor(ui): 状态显示与菜单改走后端注册表

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 6: 连接、安装、退出与 CLI 接入后端

**Files:**
- Modify: `src/AppDelegate+Connection.swift`
- Modify: `src/AppDelegate+Install.swift`
- Modify: `src/AppDelegate+Lifecycle.swift`
- Modify: `src/AppDelegate+Profiles.swift`（`switchAndReconnect`）
- Modify: `src/CommandLineTool.swift`

**Interfaces:**
- Consumes: `currentTunnelBackend()`、`selectedBackend()`、`BackendRegistry.anyActiveProcess()`、后端属性/方法
- Produces: 无新公开接口；所有 `VPMPaths` 与 `monitor` 调用点清除

- [ ] **Step 1: 连接路径**

`startConnect(_:)`：

```swift
guard let backend = BackendRegistry.backend(for: sel.profile) else {
    alert("无法连接", "不支持的 VPN 类型：\(sel.profile.backendID)")
    return
}
tunnelBackend = backend
...
let payload = backend.payload(sel.profile, cred)
let (code, out) = runWithInput("/usr/bin/sudo", ["-n", backend.connectScript], payload)
...
if self.needsInstall(backend, out) { self.askInstall { ... } } else ...
```

`waitForConnected()` 增加参数 `backend: VPNBackend`，循环内用 `backend.readyVerified()` / `backend.processPresent()`；调用处传捕获的 backend。

`autoConnectIfNeeded()`：`guard BackendRegistry.live() == nil`；sudoers 检查用 `selectedBackend()?.sudoersPath`。
`disconnect()` / `stopAfterInstall()` / `switchAndReconnect()`：一律 `currentTunnelBackend().disconnectScript`。

- [ ] **Step 2: 安装路径**

`needsInstall(_ output:)` → `needsInstall(_ backend: VPNBackend, _ output: String)`：用 `backend.sudoersPath` 与 `backend.needsInstall(output:)`。
`askInstall` / `reinstall` 用 `currentTunnelBackend()` 的 `installScript` / `installDir`（AppleScript 参数顺序：脚本、installDir、用户名）。

- [ ] **Step 3: 退出与日志**

`applicationShouldTerminate`：`BackendRegistry.anyActiveProcess()` 替代 `monitor.processPresent()`；断开用 `currentTunnelBackend().disconnectScript`。
`openLog()`：`currentTunnelBackend().logFile`。

- [ ] **Step 4: CLI**

`--vpn-on`：

```swift
guard let backend = BackendRegistry.backend(for: sel.profile) else {
    printErr("不支持的 VPN 类型：\(sel.profile.backendID)")
    exit(4)
}
let (code, out) = runWithInput("/usr/bin/sudo", ["-n", backend.connectScript],
                               backend.payload(sel.profile, cred))
```

- [ ] **Step 5: 删除旧属性并验证**

删除 `AppDelegate` 中的 `let monitor = VPNMonitor()`（此时所有引用已迁移）。

Run: `swiftc -typecheck -swift-version 5 -target arm64-apple-macos11.0 -framework Cocoa -framework Security $(find src -name '*.swift' | sort)`
Expected: 通过，且不再有 `monitor.` 引用。
Run: `tools/test.sh`
Expected: 全部 `ok`。

- [ ] **Step 6: 提交**

```bash
git add src/AppDelegate+Connection.swift src/AppDelegate+Install.swift \
        src/AppDelegate+Lifecycle.swift src/AppDelegate+Profiles.swift \
        src/CommandLineTool.swift
git commit -m "refactor(app): 连接/安装/退出/CLI 改为通过当前后端执行

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 7: 删除旧代码、更新构建与文档

**Files:**
- Delete: `src/Paths.swift`
- Delete: `src/VPNMonitor.swift`
- Modify: `src/Keychain.swift`（删除 `connectionPayload`）
- Modify: `tools/build.sh`（源码收集改为 `find`）
- Modify: `README.md`（工程结构与新增后端说明）
- Modify: `docs/zju-connect-notes.md`（如仍引用旧文件，更新）

**Interfaces:**
- Consumes: 前序任务的全部接口
- Produces: 最终可构建的工程；`tools/build.sh` 支持 `src/Backends/` 子目录

- [ ] **Step 1: 删除旧实现**

删除 `src/Paths.swift`、`src/VPNMonitor.swift`；删除 `Keychain.swift` 中 `connectionPayload` 函数。编译器应暴露任何遗漏引用。

- [ ] **Step 2: 更新构建脚本**

`tools/build.sh` 中把：

```bash
SOURCES=("$ROOT"/src/*.swift)
```

改为：

```bash
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done \
  < <(find "$ROOT/src" -name '*.swift' -type f | sort)
```

- [ ] **Step 3: 更新文档**

README 的目录说明加入：

```
src/Backends/            后端协议、注册表、通用探针、zju-connect 实现
```

并新增一小节「新增 VPN 后端」：实现 `VPNBackend` → 在 `BackendRegistry.all` 注册 → 准备脚本目录并让 `build.sh` 拷贝 → 配置 JSON 写 `"backend": "<id>"`。

- [ ] **Step 4: 全量验证**

Run: `tools/test.sh`
Expected: 全部 `ok`。
Run: `tools/build.sh`
Expected: 双架构编译、`signature ok`、`lipo -archs` 输出 `x86_64 arm64`。
Run: `package/VPNMenu.app/Contents/MacOS/VPNMenu --list-profiles`
Expected: 列出本机配置（或提示没有配置），退出码 0/1，不弹出菜单栏。

- [ ] **Step 5: 人工回归（需要真实凭据）**

逐项确认：连接 → 连接中 → 已连接；断开；连接中取消；连接中退出 App；重装组件；切换配置先断后连；登录自启自动连接；打开日志指向 `zju-connect.log`。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "refactor: 完成后端接口接入并删除旧路径/监控实现

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage**：协议/注册表（Task 3）、Profile 兼容（Task 2）、探针与 zju 实现（Task 4）、状态/菜单（Task 5）、连接/安装/退出/CLI（Task 6）、资源与构建兼容（Task 7）、选择规则与 DNS 遍历（Task 3 测试）均有任务覆盖。
- **Step scan**：每个测试步骤给出断言代码；实现步骤给出签名与搬移来源；无 TBD。
- **Type consistency**：`currentTunnelBackend()` 在 Task 5 定义、Task 6 使用；`BackendRegistry.live(in:)`、`resolve`、`repairStaleStatesIfIdle` 签名前后一致。
- **Review Focus**：五项均有对应测试或人工回归步骤。
- **Proportion**：计划以签名与测试为主，未复述实现细节。
