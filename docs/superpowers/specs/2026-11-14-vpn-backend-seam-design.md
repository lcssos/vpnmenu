# VPNMenu 多后端扩展：最小后端接口设计

日期：2026-11-14
状态：待确认

## 意图与为什么

VPNMenu 目前只会启动 zju-connect。用户后续要接入的仍是「用户名密码 + TUN」这一类
VPN，只是实现不同。现在 zju-connect 的知识散落在 7 个位置，加第二个后端必须逐个修改
`AppDelegate`、安装、退出、CLI 等调用点，容易漏。

目标是把「当前用的是哪个 VPN 实现」收进一个边界：UI、状态机、配置菜单、钥匙串、
单实例、日志这些与后端无关的部分保持不动；新增同类后端时只需新增一个实现文件和它
的运行资源，不需要改 `AppDelegate` 及其扩展。

## 目标

- 定义一个窄接口，只覆盖「用户名密码 + TUN」类后端真正需要的能力
- 把 zju-connect 的全部特有知识收进一个实现
- 旧配置 JSON、已安装组件、bundle 内路径、sudoers 规则全部保持兼容
- 现有行为、UI、CLI、日志路径、DNS 兜底逻辑零变化
- 让「新增后端」变成一个明确的、有清单的动作

## 非目标

- 同时运行多个后端隧道（仍然同一时间只有一条）
- 在 UI 里显式选择后端（由配置文件的 `backend` 字段决定）
- 支持证书 / 密钥 / `.ovpn` 文件等不同形态的配置
- 重构 `runtime/` 资源目录或改变安装路径
- 重排现有源码文件、引入插件动态加载
- 国际化（已明确不做）

## 反目标

- 为未知形态的后端提前抽象（能力协商、凭据类型系统、插件协议）
- 因为抽象而改变用户可见行为或要求已安装用户重装
- 改变 `Profile` 旧字段的语义

## 约束

- 手工构建：`tools/build.sh` 用 `swiftc` 编译，无 Xcode 工程
- 构建脚本运行在 macOS 自带的 bash 3.2，不能用 `mapfile`
- 编译输入目前是 `src/*.swift`，新增子目录必须同时修改构建脚本
- 用户配置存放在 `~/Library/Application Support/VPNMenu/profiles/*.json`
- 安装后的组件在 App 包内，sudoers 只放行现有两个启停脚本

## 方案

考虑过三种做法：

- **A. 只整理目录 + 写文档**：不引入接口。改动最小，但加后端时仍要改 7 处，耦合没解决。
- **B. 最小后端接口（本设计）**：定义协议 + 注册表，zju 成为第一个实现；资源布局和
  用户数据不动。新增同类后端只需一个实现文件 + 资源目录 + 构建脚本一行。
- **C. 完整多后端框架**：独立资源目录、多套安装、UI 选择、能力协商。只有一种后端时
  全是净负债。

选择 B。它的取舍是：`Profile` 的字段仍按 zju 的形状定义，接不同形态的后端时需要再改；
但当前已知的下一个后端是同类，这个成本可以留到真正需要时再付。

## 现状与耦合点

zju-connect 目前渗透在以下位置：

1. `Paths.swift`：脚本名、pidfile、ready 文件、日志文件、sudoers
2. `VPNMonitor.swift`：pidfile / ready 文件语义、命令行匹配 `zc-tun.sh`、`2.0.1.x` DNS 兜底
3. `Keychain.swift` 的 `connectionPayload`：zju 专用 key=value 字段
4. `AppDelegate+Connection.swift`：`sudo -n` 调启停脚本、安装判断、等待就绪
5. `AppDelegate+Install.swift`：install.sh 参数与 sudoers
6. `AppDelegate+Lifecycle.swift`：退出时调停脚本、日志路径
7. `CommandLineTool.swift` / `tools/build.sh`：`--vpn-on` 与源码 glob 写死

菜单结构、忙碌状态机、钥匙串存储、单实例、日志函数与后端无关，不在本次范围内。

## 设计

### 1. 协议

```swift
typealias Credential = (user: String, pass: String)

struct BackendStatus {
    let pid: pid_t?
    let alive: Bool
    let ready: Bool
    var connected: Bool { alive && ready }
}

protocol VPNBackend: AnyObject {
    var id: String { get }                 // 写入配置，如 "zju-connect"
    var displayName: String { get }        // 用于提示文案，如 "zju-connect"

    // 配置校验：只检查本后端特有字段；通用字段由 ProfileValidation 检查
    func validate(_ p: Profile) -> String?

    // 安装（root）
    var installScript: String { get }
    var installDir: String { get }         // install.sh 的第一个参数（VPN 组件目录）
    var sudoersPath: String { get }
    func needsInstall(output: String) -> Bool

    // 连接（root）
    func payload(_ p: Profile, _ c: Credential) -> String
    var connectScript: String { get }
    var disconnectScript: String { get }

    // 状态
    func status() -> BackendStatus
    func alivePID() -> pid_t?
    func processPresent() -> Bool
    func readyVerified() -> Bool
    func repairStaleStateIfNeeded(busy: Bool)

    var logFile: String { get }
}
```

`status()` 与三个探针方法保留，是因为现有调用点分别需要「一次性拿全状态」「主线程带缓存
的 PID」「后台线程无缓存检查」三种语义，强行合并会改变线程行为。

### 2. 注册表与后端选择规则

```swift
enum BackendRegistry {
    static let all: [VPNBackend]                 // 目前只有 ZjuConnectBackend.shared
    static func backend(id: String) -> VPNBackend?
    static func backend(for p: Profile) -> VPNBackend?
    static func active() -> VPNBackend?          // 第一个 alive 的后端（主线程）
    static func anyActiveProcess() -> Bool       // 任意后端有进程（任意线程）
    static func repairStaleStatesIfIdle(busy: Bool)
    // 没有后端存活且 !busy 时，对每个后端调用 repairStaleStateIfNeeded
}
```

选择规则（以「实际在跑的隧道」为准，而不是当前选中的配置）：

- App 在**发起连接**时把后端记录为 `tunnelBackend`，即使 pidfile 还没出现；`refresh()`
  观察到没有任何后端存活、且不处于 `busy` / `waitingReady` 时清空它。
- `currentTunnelBackend()` 按顺序取：
  1. 第一个 `processPresent()` 为 true 的后端（隧道确实在跑）
  2. `tunnelBackend`（已发起连接、进程尚未出现）
  3. 选中配置的后端
  4. 第一个注册的后端（保证日志/安装等动作没有配置时也有目标）
- **连接**：用选中配置的后端，同时写入 `tunnelBackend` 并捕获进等待循环；等待期间切换
  选中项不影响正在进行的连接。
- **断开 / 退出 / 切换配置**：一律用 `currentTunnelBackend()`。这样「连接 A 后立刻把
  选中项切到 B、此时 A 的进程还没出现」也会去停 A，不会误停 B。
- **状态显示**：只认实际存活的后端，没有存活就显示未连接；不使用选中项兜底。
- **日志 / 重新安装**：用 `currentTunnelBackend()`；没有选中配置时兜底到第一个后端，
  保持现在「零配置也能打开日志/重装」的行为。
- **残留状态修复**：`refresh()` 在没有后端存活且 `!busy` 时，对**每个**注册后端调用
  `repairStaleStateIfNeeded`。这样即使删掉/切换了配置、或当前选中的不是 zju 配置，
  `2.0.1.x` 的残留 DNS 仍会被还原，与现在的行为一致；每个后端只对自己的残留特征负责。
- **未知 `backend` 值**：`backend(for:)` 返回 nil，`ProfileStore.list()` 与现在对非法
  配置的处理一致——静默跳过。不做「连接时再报错」，因为这类配置根本不会被选中或导入；
  降级/手改 JSON 产生的未知后端对自己不可见，视为可接受。

### 3. Profile 变更

- 新增 `var backend: String?`
- `backendID` 计算属性：`backend ?? "zju-connect"`
- 自定义 `encode(to:)`，`backend` 为 nil 时不写该字段；旧 JSON 解码为 nil，行为不变
- 导出格式不会出现 `"backend": null`

### 4. 校验拆分

- `ProfileValidation.commonError(for:)`：名称、服务器 host、端口
- `ZjuConnectBackend.validate`：`tunInterface`、`socksBind`、`httpBind`、域名数量与格式
- `ProfileStore.list()` / `importProfile` 统一走注册表校验，错误文案保持现有措辞
- 未知后端：导入时报「不支持的 VPN 类型：<id>」；已经存在的未知后端文件由 `list()`
  静默跳过（与现在处理非法配置的方式一致）

### 5. 状态探测抽取

把 `VPNMonitor` 中与后端无关的部分抽成 `ProcessFileProbe`：

```swift
final class ProcessFileProbe {
    struct Config {
        let pidFile: String
        let readyFile: String
        let commandMarker: String   // ps 命令行中必须包含的字符串
    }
    // alivePID / processPresent / readyVerified / tunnelReady 的实现原样搬入，
    // 包括 verifiedPID + 启动时间缓存、kill(0)、sysctl、首次见 PID 才跑 ps
}
```

`ZjuConnectBackend` 持有 probe 与 DNS 兜底逻辑（`hasStaleDNS` / 30 秒节流的修复），
对外暴露协议方法。DNS 逻辑不进入通用探针。

### 6. 调用点改造

| 文件 | 现状 | 改为 |
|---|---|---|
| `AppDelegate.swift` | `monitor.alivePID/tunnelReady/hasStaleDNS/repairStaleDNS` | 取一次实际存活的后端，用其 `status()` / `alivePID()`；无存活且空闲时 `BackendRegistry.repairStaleStatesIfIdle(busy:)` |
| `AppDelegate+Connection.swift` | `VPMPaths.on/off/sudoers`、`monitor.*` | 连接用选中配置的后端（并记录 `tunnelBackend`）；断开用 `currentTunnelBackend()`；等待循环捕获发起连接的后端 |
| `AppDelegate+Profiles.swift` | `VPMPaths.off`、`monitor.alivePID` | `currentTunnelBackend().disconnectScript` / `alivePID()` |
| `AppDelegate+Install.swift` | `VPMPaths.install/vpnDir/sudoers` | 选中后端的 `installScript/installDir/sudoersPath` |
| `AppDelegate+Lifecycle.swift` | `VPMPaths.logFile/off`、`monitor.processPresent` | 后端的 `logFile/disconnectScript`；`anyActiveProcess()` |
| `AppDelegate+MenuBar.swift` | `monitor.alivePID` | `activeBackend().alivePID()` |
| `CommandLineTool.swift` | `VPMPaths.on` | 选中配置的后端 `connectScript` |
| `Keychain.swift` | `connectionPayload` | 移入 `ZjuConnectBackend` |
| `Profile.swift` | 单体校验 | 通用校验 + 注册表校验 |
| `VPNMonitor.swift` | zju 专属 | 拆为 `Backends/ProcessFileProbe.swift` + 后端内的 DNS 逻辑 |
| `Paths.swift` | 全局常量 | 删除，zju 路径移入 `ZjuConnectBackend` |
| `tools/build.sh` | `src/*.swift` | `find src -name '*.swift'` |

### 7. 目录与构建

```
src/
  Backends/
    VPNBackend.swift         协议、BackendStatus、注册表
    ProcessFileProbe.swift   通用 pidfile/ready 探测
    ZjuConnectBackend.swift  第一个实现
  ...现有文件保持原位
```

构建脚本改为用 `find` 收集源码，兼容 bash 3.2：

```bash
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done \
  < <(find "$ROOT/src" -name '*.swift' -type f | sort)
```

### 8. 线程约定

- `status()`、`alivePID()`、`repairStaleStateIfNeeded`：仅主线程（缓存不加锁）
- `processPresent()`、`readyVerified()`：任意线程（只读文件与系统调用）
- `validate`、`payload`、路径属性：纯函数，任意线程
- 注册表初始化在主线程首次访问

### 9. 资源与安装

`runtime/vpn/` 与包内 `Contents/Resources/vpn/` 保持不变，`install.sh`、sudoers
规则、pidfile / ready 文件路径全部不动，已安装用户无需重装。`build.sh` 里对
`runtime/vpn` 和 `vendor/zju-connect-*` 的拷贝保持现状。

第二个后端落地时才引入 `runtime/backends/<id>/` 布局，并单独设计安装路径迁移
（sudoers 指向旧路径的问题）。

## 新增后端时要做的事

1. 新建 `src/Backends/<Name>Backend.swift`，实现协议，在 `BackendRegistry.all` 注册
2. 准备该后端自己的运行脚本目录，`build.sh` 增加拷贝，安装脚本写自己的 sudoers
3. 配置 JSON 带 `"backend": "<id>"`；不带时视为 `zju-connect`
4. `AppDelegate` 及其扩展、状态机、菜单、钥匙串不需要修改

## 兼容与迁移

- 旧配置（无 `backend`）→ `zju-connect`
- 已安装组件、sudoers、bundle 路径、日志路径不变
- CLI 参数不变
- 选中配置的 `backend` 未知时不会崩溃：列表跳过，连接报错

## 验证与回归

构建与静态检查：

- `tools/build.sh` 双架构编译 + 签名通过
- `swiftc -typecheck` 通过
- `tools/build.sh --dist` 可选用

配置与 CLI：

- 用不带 `backend` 的旧 JSON 执行 `--import-profile`、`--list-profiles` 正常
- 导出后再导入，字段与现在一致（不出现 `backend: null`）
- `--vpn-on` 行为与输出不变

运行时（需要真实凭据，部分需用户配合）：

- 连接：忙碌动画 → 连接中 → 已连接，5 秒轮询内状态正确
- 断开、连接中取消、连接过程中退出 App
- 首次安装 / 重装组件的提示与提权流程
- 切换配置时先断开再重连
- 登录自启后的自动连接
- 日志菜单打开的是 `~/Library/Logs/VPNMenu/zju-connect.log`
- DNS 兜底路径代码未变（人工难以稳定复现，靠代码审阅）

## Builder 审核后的决定

独立审核提出 4 个会导致实现出错的空白，处理如下（均不改变用户可见行为）：

1. **断开目标的歧义**：以「实际在跑的隧道」为准。连接时记录 `tunnelBackend`，
   断开/退出/切换用 `currentTunnelBackend()`，避免「连接 A 后立刻选中 B、A 的进程还没
   出现」时误停 B。见 §2。
2. **残留 DNS 修复的覆盖范围**：由注册表在没有后端存活且空闲时遍历所有后端，
   保持现在「无配置也能修复」的行为，不依赖当前选中的配置。见 §2、§6。
3. **未知 backend 的既有配置**：`list()` 静默跳过（沿用非法配置的处理），导入时报错；
   不要求连接时再报错。见 §4。
4. **零配置下的日志/重装**：兜底到第一个注册后端，保持现有行为。见 §2。
5. **文档笔误**：`install.sh` 的第一个参数是 VPN 组件目录，第二个是用户名，已修正。

## 风险

- 调用点遗漏：由编译器兜底（删除 `VPMPaths` 与 `monitor` 会暴露所有引用）
- 行为漂移：安装判断、等待就绪、DNS 节流三处逻辑原样搬移，人工回归
- 线程契约破坏：探针方法签名不变，等待循环仍只调用无缓存的 `processPresent/readyVerified`
- 构建脚本改动导致漏编文件：用 `find` 后检查 `lipo` 产物与运行行为

## 留给实现者的判断

- 协议方法的具体命名与文件划分
- `status()` 是组合 probe 结果还是由后端自行缓存
- `Credential` 用 typealias 还是 struct（倾向 typealias，减少现有代码改动）
- 是否保留 `Paths.swift` 作为共享路径入口（若删除，需确认没有其他隐式依赖）
