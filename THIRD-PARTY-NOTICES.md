# 第三方组件与许可声明

VPNMenu 本体以 **GNU Affero General Public License v3.0（AGPL-3.0）** 发布，
Copyright (C) 2026 lcssos，全文见 [LICENSE](LICENSE)。

App 包和分发的 zip 中同时包含以下第三方组件，其许可与获取方式如下。

## zju-connect

| 项目 | 内容 |
|---|---|
| 项目主页 | https://github.com/Mythologyli/zju-connect |
| 版本 | v1.3.1（`zju-connect --version` 输出 `ZJU Connect v1.3.1`） |
| 许可证 | AGPL-3.0，全文见 [licenses/AGPL-3.0.txt](licenses/AGPL-3.0.txt) |
| 版权 | Copyright (C) Mythologyli 及 zju-connect 贡献者 |

VPNMenu 以**独立进程**方式调用 zju-connect：App 通过 stdin 传入连接参数，不链接、
不修改其源码或二进制。App 包内分发的是从上游 release 下载的官方 darwin 二进制
（`zju-connect-darwin-amd64` 与 `zju-connect-darwin-arm64`），仅用 `lipo` 合并成
通用二进制并重新签名，代码零改动。

对应源码：

- 源码标签：https://github.com/Mythologyli/zju-connect/tree/v1.3.1
- 发布页面：https://github.com/Mythologyli/zju-connect/releases/tag/v1.3.1

zju-connect 自身的 Go 依赖及其许可证见上游仓库的 `go.mod` / `go.sum`。

> **AGPL-3.0 §6 提示**：分发包含该二进制的 App 时，请保留本文件与
> `licenses/AGPL-3.0.txt`。若需要未修改二进制的完整对应源码，可从上述源码地址获取；
> 也可以通过本仓库的 Issues 联系维护者索取书面副本。

## 其他

- App 图标由本仓库的 `tools/make-icon.swift` 生成，不使用第三方图像资源。
- 菜单栏图标使用 macOS 自带的 SF Symbols（如 `lock.shield`），在运行时由系统渲染，
  不随本仓库或 App 分发。
