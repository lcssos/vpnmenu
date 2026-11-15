# VPNMenu 内置组件说明

App 内所有运行组件都在这个目录，安装后会被 chown 成 root:wheel（除本说明外）：

| 文件 | 作用 |
|---|---|
| `zju-connect` | 通用二进制（x86_64 + arm64），替代 EasyConnect 客户端 |
| `zc-tun.sh` | 启动 TUN、等隧道就绪、设置系统 DNS、写就绪标记、注入域名 /32 路由（root） |
| `zc-vpn-on` / `zc-vpn-off` | 启停入口，sudoers 只放行这两个 |
| `zc-vpn-status` | 命令行状态查询（普通用户可跑）；输出 `connected` / `connecting` / `disconnected`，退出码 `0` / `2` / `1`。App 现在进程内检查状态，脚本保留给排障 |
| `zc-dns-restore` | 按启动前快照还原 `zc-tun.sh` 接管的系统 DNS（root，崩溃兜底） |
| `install.sh` | 一次性安装：权限、sudoers、清理旧版组件 |
| `uninstall.sh` | 停止 VPN、撤销 sudoers 规则、移除登录自启（需要 root，会自行提权） |

### 就绪标记

`zc-tun.sh` 要等 utun 出现、DNS 可用、初始 `/32` 路由写完，才写
`/var/run/zju-connect.ready`（内容为 `包装脚本pid zju-connect进程pid`）。
App 和 `zc-vpn-status` 都以这个标记判断「已连接」，而不只是看进程活着。

启动过程中 zju-connect 提前退出（认证失败、服务端拒绝等）或 utun 40 秒内没出现时，
`zc-tun.sh` 会记录日志并直接退出，不会先报已连接再等超时。退出时 pid 文件和就绪标记
都会被清理。

## 第三方组件

`zju-connect` 是 [Mythologyli/zju-connect](https://github.com/Mythologyli/zju-connect)
的官方 v1.3.1 二进制（**AGPL-3.0**）。App 以独立进程方式调用，未修改其代码。

许可证原文与声明随 App 一起分发：

```
Contents/Resources/licenses/AGPL-3.0.txt
Contents/Resources/THIRD-PARTY-NOTICES.md
```

**这个目录里没有服务器地址、域名列表或账号密码。** 连接参数来自本机配置：

```
~/Library/Application Support/VPNMenu/profiles/<uuid>.json   # 服务器/端口/域名，用户可写
macOS 登录钥匙串（com.lcssos.vpnmenu.credential.<uuid>）      # 账号密码
```

App 解析配置后，把参数以 `key=value` 形式通过 **stdin** 交给 `zc-vpn-on`；它只按白名单
取值并做格式校验（hostname、端口、utun 名、监听地址），然后把值放进环境变量交给
`zc-tun.sh`。root 侧从不 `source`/`eval` 用户可写的文件，避免把配置目录变成提权入口。

## 系统 DNS 与异常退出后的还原

系统 DNS 默认由 `zc-tun.sh` 接管：启动 zju-connect 时传 `-dns-hijack=false`——原来的
`-dns-hijack` 会在启动时串行遍历**所有**网络服务改 DNS，每个服务 1–2 秒，通常要多等
10 秒。utun 就绪后，脚本只对**当前有 IPv4 地址**的网络服务设置 DNS（通常只有
Wi-Fi/有线一个，约 2 秒），设置的值记在 `/var/run/zju-connect.dns.active`。

配置里的 `dnsMode` 可以切回 zju-connect 的实现：`script`（默认）走上面的脚本逻辑；
`zju` 保留 zju-connect 的 `-dns-hijack`，此时脚本不再设置系统 DNS。`multiLine` 同理：
`script`（默认）传 `-disable-multi-line`，跳过登录后的线路 ping 测速；`zju` 交还
zju-connect 自动选线。

`dnsMode=script` 时，`apply_system_dns` 在设置每个服务前把原值记到
`/var/run/zju-connect.dns`（只记录实际被修改的服务）；`dnsMode=zju` 时仍在启动前
全量快照（zju-connect 会改所有服务）。以下三条路径都会调用 `zc-dns-restore`
按快照还原（只动仍指向 VPN DNS 或被清空的服务）：

1. `zc-tun.sh` 的 EXIT 清理（每 5 秒检查子进程，panic 后最多 5 秒触发）；
2. `zc-vpn-off`（覆盖 `kill -9` / 手动清理）；
3. App 断开状态下读取 `/etc/resolv.conf`，发现仍是 VPN DNS 时自动调用 `zc-vpn-off`。

## 安装时发生了什么

App 首次点「连接」会弹管理员密码，以 root 运行 `install.sh`：

1. 停止正在运行的实例；
2. 删除旧版的 `/usr/local/libexec/zju-connect`、`/usr/local/bin/zc-vpn-*`、`/etc/sudoers.d/zc-vpn`；
3. 把本目录 `chown root:wheel`、脚本 755，并删除旧版明文 `.pw` 和旧版包内 `vpn.conf`；
4. 写 `/etc/sudoers.d/vpnmenu`，只允许当前用户免密执行本目录下的 `zc-vpn-on` / `zc-vpn-off`。

运行期在 App 外只剩这些：

- `/etc/sudoers.d/vpnmenu`（免密规则，必须由系统读取）
- `/var/run/zju-connect.pid`（运行时 PID）
- `/var/run/zju-connect.ready`（隧道就绪标记）
- `/var/run/zju-connect.dns.active`（当前设置的 VPN DNS，退出时删除）
- `~/Library/Logs/VPNMenu/zju-connect.log`（日志，超过 5MB 时轮转为 `.log.1`）
- `~/Library/LaunchAgents/com.lcssos.vpnmenu.plist`（登录自启，`install.sh` 不碰它，
  `uninstall.sh` 会删除）
- `~/Library/Application Support/VPNMenu/profiles/`（本机配置，App 升级不会动它）

## 换一台电脑

1. 把整个 `VPNMenu.app` 拷到 `/Applications`；
2. 打开 App，在「配置 → 导入配置…」导入 JSON（或手动放进配置目录）；
3. 首次连接前，在「设置账号…」录入该配置的账号密码（保存到钥匙串）；
4. 首次连接会弹管理员密码安装组件，之后菜单栏点「连接」即可。

> 如果是从网络下载的压缩包，首次运行前可能需要：
> `xattr -dr com.apple.quarantine /Applications/VPNMenu.app`
