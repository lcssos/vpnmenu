# VPNMenu

菜单栏 VPN 开关，用 zju-connect 替代 EasyConnect 客户端。**所有运行组件都在 App 内部**，
拷贝到另一台 Mac 的 `/Applications` 后，首次连接输一次管理员密码即可使用。

**本仓库不含任何公司内网信息**：服务器地址、域名路由、账号密码都不在源码或 App 包里，
配置保存在使用者本机（见「配置与隐私」）。

## 目录

源码（进 git）：

```
src/main.swift          菜单栏 App 源码（状态、连接/断开、配置、钥匙串、安装提示、自启动）
src/Info.plist          bundle 元信息（LSUIElement=true，CFBundleIconFile=VPNMenu）
runtime/vpn/            运行期脚本（zc-*.sh、install.sh、组件说明）
docs/profile.example.json  配置格式示例（占位值，可直接作为导入模板）
docs/                   旧方案原理笔记（历史文档）
tools/build.sh          从源码组装通用 App
tools/deploy.sh         构建并部署到 /Applications
tools/make-icon.swift   生成 App 图标（1024px PNG → iconset → icns）
```

产物（不进 git，`tools/build.sh` 生成）：

```
build/                  中间产物（两个架构的 App 二进制、make-icon）
assets/                 图标产物（icon-1024.png、VPNMenu.iconset、VPNMenu.icns）
vendor/                 zju-connect 的 amd64/arm64 原件，用于合成通用二进制
package/VPNMenu.app     组装好的 App（部署/分发的来源）
dist/VPNMenu.zip        给另一台电脑用的压缩包
```

已安装的 `/Applications/VPNMenu.app` 是**部署产物**，不是原件：改东西请改 `src/` 和
`runtime/`，然后 `tools/build.sh` 重新组装并部署。

App 内部结构：

```
Contents/Resources/vpn/
  zju-connect            通用二进制（x86_64 + arm64）
  zc-tun.sh              启动 TUN、等就绪、注入域名 /32 路由
  zc-vpn-on / -off       启停入口（sudoers 只放行这两个）
  zc-vpn-status          状态查询（残留 VPN DNS 时输出 dns=stale）
  zc-dns-restore         按快照还原被 dns-hijack 改写的系统 DNS（崩溃兜底）
  install.sh             一次性安装：chown root、写 sudoers、清理旧组件
  uninstall.sh           撤销
  README.md              组件说明
```

## 配置与隐私

配置与程序分离，**配置永远不进入 App 包，也不进 git**：

```
~/Library/Application Support/VPNMenu/profiles/<uuid>.json
```

一份配置只包含网络参数（不含账号密码）：

```json
{
  "schema": 1,
  "name": "公司 VPN",
  "server": "vpn.example.com",
  "port": 4430,
  "tunInterface": "utun4",
  "socksBind": "127.0.0.1:1090",
  "httpBind": "127.0.0.1:1091",
  "proxyDomains": ["legacy.example.com"],
  "domains": ["app.example.com", "db.example.com"]
}
```

字段说明：

- `domains`：需要走隧道、且服务端 rclist 未下发 IP 的域名。连接后脚本用内网 DNS 解析，
  把结果注入 `/32` 路由；每 5 分钟刷新。
- `proxyDomains`：需要额外传给 zju-connect `-custom-proxy-domain` 的域名。
- `tunInterface` / `socksBind` / `httpBind` / `port` 可省略，默认 `utun4` /
  `127.0.0.1:1090` / `127.0.0.1:1091` / `4430`。

日常操作：

- 菜单栏 **配置 → 导入配置…**：选择一个 JSON，导入为新配置并选中；
- **配置 → 导出当前配置…**：导出一份不含凭据的 JSON，方便带到另一台电脑；
- **配置 → 删除当前配置…**：同时删除该配置在钥匙串里的账号密码；
- **配置 → 显示配置目录**：直接打开本机配置目录。

可以导入多份配置，菜单里用单选切换。已连接时切换会先断开再按新配置重连。

> 安全设计：root 脚本只从 App 的 **stdin** 接收白名单 `key=value` 并校验格式，
> 从不 `source`/`eval` 本机配置文件。用户可写的 JSON 不会被 root 当作代码执行。

## 凭据（不落盘，存钥匙串）

每个配置一份凭据，存在 macOS **登录钥匙串**，服务名
`com.lcssos.vpnmenu.credential.<配置 uuid>`：

- 首次连接某配置时如果钥匙串里没有，会弹框录入；之后可用菜单「设置账号…」修改；
- 连接时 App 从钥匙串取出，通过 **stdin** 传给 root 脚本（不进 argv，不出现在 `ps` 里），
  脚本再以 `ZJU_CONNECT_PASSWORD` 环境变量交给 zju-connect，进程退出即消失；
- 工程和 App 包内没有 `.pw`、用户名或密码；
- 从旧版本升级时，首次读取会把旧的全局条目 `com.lcssos.vpnmenu.credential`
  自动迁移到当前配置名下并删除旧条目。

命令行维护（可选）：

```bash
APP=/Applications/VPNMenu.app/Contents/MacOS/VPNMenu

# 导入配置并选中（会打印新配置 id）
$APP --import-profile ./work-vpn.json

# 列出本机配置（* 表示当前选中）
$APP --list-profiles

# 为当前选中的配置写入/覆盖凭据（stdin 两行：用户名、密码）
printf '%s\n%s\n' '用户名' '密码' | $APP --set-credential

# 用当前配置 + 钥匙串凭据直接连接（排障用）
$APP --vpn-on
```

> 注意：App 是 ad-hoc 签名，**重新签名/更新后首次读钥匙串会弹一次「允许访问」**，
> 点「始终允许」即可。钥匙串条目绑定的是二进制签名，不是明文。
>
> 卸载 App 不会自动删除钥匙串条目；需要的话在「钥匙串访问」里搜
> `com.lcssos.vpnmenu.credential` 删除，或运行
> `security delete-generic-password -s com.lcssos.vpnmenu.credential`。

## 构建

```bash
~/opt/vpnmenu/tools/build.sh           # 只组装 package/VPNMenu.app
~/opt/vpnmenu/tools/build.sh --dist    # 同时打包 dist/VPNMenu.zip
```

脚本会分别交叉编译 x86_64 与 arm64，再用 `lipo` 合成通用二进制，并重新签名。
产物里两个 Mach-O 都是 `x86_64 + arm64`：

- `Contents/MacOS/VPNMenu`（App 本体）
- `Contents/Resources/vpn/zju-connect`（VPN 客户端）

所以同一个 `VPNMenu.app` 在 Intel 和 Apple Silicon 上都能原生运行，不需要 Rosetta。
想只出单一架构时，改 `tools/build.sh` 里保留其中一个 `swiftc -target` 即可。

图标重新生成见 `tools/make-icon.swift` 顶部注释（`make-icon` → `sips` → `iconutil`）。

## 部署 / 更新

```bash
tools/deploy.sh            # 部署现有产物
tools/deploy.sh --build    # 先构建再部署
```

脚本流程：`ditto` 覆盖 `/Applications/VPNMenu.app` → 跑 `install.sh`（chown root、
写 sudoers、停旧实例）→ 重启菜单栏进程；部署前若 VPN 是连接状态，会用本机配置和
钥匙串凭据自动恢复连接。会弹一次管理员密码。

也可以直接在菜单里点「重新安装组件…」。

## 分发

```bash
~/opt/vpnmenu/tools/build.sh --dist
```

等价于构建后手动执行
`ditto -c -k --sequesterRsrc --keepParent package/VPNMenu.app dist/VPNMenu.zip`。

另一台 Mac：解压 → 拖到 `/Applications` → 打开 → 导入配置 → 录入账号 →
首次连接时输入管理员密码。如提示「无法验证开发者」（AirDrop/下载带 quarantine）：

```bash
xattr -dr com.apple.quarantine /Applications/VPNMenu.app
```

压缩包里**不含配置**；把导出的 JSON 单独传过去即可。

## 安装后 App 之外还剩什么

- `/etc/sudoers.d/vpnmenu` —— 只允许当前用户免密执行 App 内的 `zc-vpn-on` / `zc-vpn-off`
- `/var/run/zju-connect.pid` —— 运行时 PID
- `~/Library/Logs/VPNMenu/zju-connect.log` —— 日志
- `~/Library/Application Support/VPNMenu/profiles/` —— 本机配置（不进包、不进 git）
- `~/Library/LaunchAgents/com.lcssos.vpnmenu.plist` —— 登录自启（App 启动时自动维护路径）

## 已知坑

- **内网 DNS 地址不是固定的**：zju-connect 的虚拟 IP 每个会话可能是 `2.0.1.1` 或
  `2.0.1.2`，DNS 就监听在这个地址上。`zc-tun.sh` 从 utun 接口地址动态读取，不能写死。
- **单会话**：同一账号只允许一个 VPN 会话，不要在连接期间再起第二个 zju-connect。
- **路径不能含空格**：sudoers 的路径匹配不支持空格，`install.sh` 会直接报错。
- **配置目录不要提交**：`.gitignore` 已加 `profiles/` 与 `*.vpnprofile.json` 兜底，
  提交前仍建议搜一下内网 IP/域名。
