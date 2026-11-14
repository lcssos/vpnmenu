> **历史文档**：这是 2026-11 早期版本（组件散落在 `/usr/local`、`~/opt/zju-connect`）的
> 原理笔记，部分路径已不适用。当前实现全部收在 `/Applications/VPNMenu.app` 内，
> 见 `~/opt/vpnmenu/README.md`。

# zju-connect on this Mac

用 zju-connect（v1.3.1, darwin-amd64）替代深信服 EasyConnect 客户端。
服务端不变：`vpn.example.com:4430`（EasyConnect 协议，M7.6.7R1）。

## 文件

| 文件 | 说明 |
|---|---|
| `zju-connect` | 客户端二进制 |
| `zc-tun.sh` | TUN 模式启动脚本（需 root） |
| `zc-tun-stop.sh` | 停止脚本（需 root） |
| `zc.sh` | 纯 SOCKS5/HTTP 模式（无需 root），**不能与 TUN 同时运行** |
| `.pw` | VPN 密码（600 权限，明文） |
| `zc-tun.log` / `zc.log` | 日志 |

## 启动 TUN 模式（等价 EasyConnect 的 L3 隧道）

```bash
# 先退出 EasyConnect，避免 utun/路由冲突
osascript -e 'tell application "EasyConnect" to quit'
sudo /Users/lcssos/opt/zju-connect/zc-tun.sh >> /Users/lcssos/opt/zju-connect/zc-tun.log 2>&1 &
```

启动后：
- 虚拟网卡 `utun4`，地址 `2.0.1.1`，MTU 1400
- 服务端下发的 `/32` 路由（172.16.x 内网 + 阿里云 IP + DNS）
- **域名型资源**（`app.example.com`、云厂商的 RDS/Kibana/Nacos 域名等）
  由脚本解析后额外注入 `/32` 路由，每 5 分钟刷新
- 默认路由不变（分流模式）
- 附带代理：SOCKS5 `127.0.0.1:1090`、HTTP `127.0.0.1:1091`

## 停止

```bash
sudo /Users/lcssos/opt/zju-connect/zc-tun-stop.sh
```

## 为什么需要额外注入域名路由

`stack/tun/dial_darwin.go` 里，目标 IP 不在 `ipSet` 时直接走物理网卡：

```go
if ok && s.endpoint.ipSet.Contains(prefix) {
    return s.endpoint.tcpDialer.Dial(...)   // 进隧道
}
return net.DialTCP("tcp4", nil, addr)       // DIRECT
```

而 `-add-route` 只处理服务端下发的 **IP 资源**，不处理**域名资源**解析出的 IP。
官方 EasyConnect 的做法也是把域名解析结果加进路由表，所以 `zc-tun.sh` 里补了这一步。

对于**服务端 rclist 里没有、但实际属于内网**的域名（例如 `legacy.example.com`，
服务端只下发了 `app.example.com`），还需要同时做两件事：

1. 在 zju-connect 参数里用 `-custom-proxy-domain 'legacy.example.com'` 显式声明为域名资源
2. 把域名加入脚本的 `DOMAINS` 数组，以自动注入路由

否则该域名的 IP 既不在 IP 资源表、也匹配不到域名资源，TUN 会丢弃发往 `utun4`
的包，直连和公网出口也都不可达。

## 重要限制：同一账号只能有一个会话

深信服网关按用户只保留一个会话。**不要在 TUN 实例运行时再启动 `zc.sh` /
另一个 zju-connect**——新会话会把旧会话顶掉，而 zju-connect 的 TUN 栈在重连时会
`panic: unexpected recv handshake reply`，导致整个隧道（含内网）中断。

## 恢复 EasyConnect

先停止 zju-connect（否则 utun/路由冲突），再打开 EasyConnect。

## 菜单栏开关（VPNMenu）

日常使用不用再开终端，用菜单栏图标控制：

- 图标位置：菜单栏右侧。颜色跟其它菜单栏图标一致（深色主题纯白、浅色纯黑），
  状态只看形状：实心盾牌 `lock.shield.fill` = 已连接，空心 `lock.shield` = 未连接
- 菜单项：状态 / 连接 / 断开 / 打开日志 / 退出
- 每 2 秒刷新一次状态，点「连接」后会等到状态变为已连接才恢复按钮

App 位置与自启动：

```
~/Applications/VPNMenu.app
~/Library/LaunchAgents/com.lcssos.vpnmenu.plist   # 登录自动启动
```

源码在 `~/opt/vpnmenu/src/`（`*.swift` + `Info.plist`），重新编译安装：

```bash
cd ~/opt/vpnmenu
swiftc -O -swift-version 5 -framework Cocoa -o VPNMenu.app/Contents/MacOS/VPNMenu src/*.swift
codesign --force --sign - --timestamp=none VPNMenu.app
rm -rf ~/Applications/VPNMenu.app && cp -R VPNMenu.app ~/Applications/
launchctl kickstart -k gui/$(id -u)/com.lcssos.vpnmenu
```

菜单里点「退出」只退出 App（KeepAlive=false，不会自动拉起），下次登录仍会自动启动；
想立刻手动打开：`open -a ~/Applications/VPNMenu.app`。

### App 图标

图标是脚本画的（圆角方形蓝渐变 + 白色盾牌），不是手工图片：

- 生成脚本：`~/opt/vpnmenu/tools/make-icon.swift`
- 产物：`~/opt/vpnmenu/assets/icon-1024.png` → `assets/VPNMenu.icns`

重新生成并装进 App：

```bash
cd ~/opt/vpnmenu/tools
swiftc -O -swift-version 5 -framework Cocoa -o make-icon make-icon.swift
./make-icon ../assets/icon-1024.png
# 生成 iconset（16/32/64/128/256/512/1024）
cd ../assets && rm -rf VPNMenu.iconset && mkdir VPNMenu.iconset
for s in 16 32 64 128 256 512; do sips -z $s $s icon-1024.png --out VPNMenu.iconset/icon_${s}x${s}.png >/dev/null; done
sips -z 1024 1024 icon-1024.png --out VPNMenu.iconset/icon_512x512@2x.png >/dev/null
iconutil -c icns VPNMenu.iconset -o VPNMenu.icns
cp VPNMenu.icns ~/Applications/VPNMenu.app/Contents/Resources/
touch ~/Applications/VPNMenu.app
```

Info.plist 里靠 `CFBundleIconFile = VPNMenu` 指向 `Contents/Resources/VPNMenu.icns`。

### 免密背后的东西

App 本身不持 root，只调用已安装的 root 脚本：

```
/usr/local/libexec/zju-connect/{zju-connect,zc-tun.sh,.pw}   # root:wheel，.pw 600
/usr/local/bin/{zc-vpn-on,zc-vpn-off,zc-vpn-status}
/etc/sudoers.d/zc-vpn   # 只放行 zc-vpn-on / zc-vpn-off，不用输密码
```

安装/重装这些 root 组件：`sudo bash ~/opt/zju-connect/staging/install-root.sh`

> 注意：`zc-vpn-status` 普通用户判断 root 进程不能用 `kill -0`（返回 EPERM），
> 必须用 `ps -p <pid>`，脚本里已按此实现。
