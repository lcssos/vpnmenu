# VPNMenu 内置组件说明

App 内所有运行组件都在这个目录，安装后会被 chown 成 root:wheel（除本说明外）：

| 文件 | 作用 |
|---|---|
| `zju-connect` | 通用二进制（x86_64 + arm64），替代 EasyConnect 客户端 |
| `zc-tun.sh` | 启动 TUN、等隧道就绪、注入域名 /32 路由（root） |
| `zc-vpn-on` / `zc-vpn-off` | 启停入口，sudoers 只放行这两个 |
| `zc-vpn-status` | 命令行状态查询（普通用户可跑）；App 现在进程内检查状态，脚本保留给排障 |
| `zc-dns-restore` | 按启动前快照还原被 `-dns-hijack` 改写的系统 DNS（root，崩溃兜底） |
| `install.sh` | 一次性安装：权限、sudoers、清理旧版组件 |
| `uninstall.sh` | 撤销 sudoers 规则并停止 VPN |

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

## 隧道异常退出后的 DNS 还原

`-dns-hijack` 会把各网络服务的 DNS 改成 VPN 内网地址（`2.0.1.x`）。zju-connect 正常
退出时会自己还原，但它在 TUN 重连时 `panic`，那条路径不会执行清理——系统 DNS 会一直
指向已经不可达的内网地址，整机域名解析失效。

所以启动前 `zc-tun.sh` 会把各服务原始 DNS 记到 `/var/run/zju-connect.dns`，以下三条
路径都会调用 `zc-dns-restore` 按快照还原（只动仍指向 `2.0.1.x` 或被清空的服务）：

1. `zc-tun.sh` 的 EXIT 清理（每 5 秒检查子进程，panic 后最多 5 秒触发）；
2. `zc-vpn-off`（覆盖 `kill -9` / 手动清理）；
3. App 断开状态下读取 `/etc/resolv.conf`，发现仍是 `2.0.1.x` 时自动调用 `zc-vpn-off`。

## 安装时发生了什么

App 首次点「连接」会弹管理员密码，以 root 运行 `install.sh`：

1. 停止正在运行的实例；
2. 删除旧版的 `/usr/local/libexec/zju-connect`、`/usr/local/bin/zc-vpn-*`、`/etc/sudoers.d/zc-vpn`；
3. 把本目录 `chown root:wheel`、脚本 755，并删除旧版明文 `.pw` 和旧版包内 `vpn.conf`；
4. 写 `/etc/sudoers.d/vpnmenu`，只允许当前用户免密执行本目录下的 `zc-vpn-on` / `zc-vpn-off`。

运行期在 App 外只剩这些：

- `/etc/sudoers.d/vpnmenu`（免密规则，必须由系统读取）
- `/var/run/zju-connect.pid`（运行时 PID）
- `~/Library/Logs/VPNMenu/zju-connect.log`（日志）
- `~/Library/Application Support/VPNMenu/profiles/`（本机配置，App 升级不会动它）

## 换一台电脑

1. 把整个 `VPNMenu.app` 拷到 `/Applications`；
2. 打开 App，在「配置 → 导入配置…」导入 JSON（或手动放进配置目录）；
3. 首次连接前，在「设置账号…」录入该配置的账号密码（保存到钥匙串）；
4. 首次连接会弹管理员密码安装组件，之后菜单栏点「连接」即可。

> 如果是从网络下载的压缩包，首次运行前可能需要：
> `xattr -dr com.apple.quarantine /Applications/VPNMenu.app`
