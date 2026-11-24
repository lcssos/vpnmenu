// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Dispatch
import Foundation

/// 监听隧道包装脚本（zc-tun.sh）的退出事件。
///
/// 用 kqueue 的 NOTE_EXIT，而不是定时轮询：稳态下零唤醒、不启动子进程，
/// zju-connect panic 或包装脚本被终止时能立刻回调。pid 来自 pidfile，
/// 只在主线程使用（与 ProcessFileProbe 的约定一致）。
final class TunnelProcessWatcher {
    private var source: DispatchSourceProcess?
    private(set) var pid: pid_t = -1

    /// 被监听的进程退出时在主线程调用。
    var onExit: (() -> Void)?

    /// 改为监听指定 PID；同一个 PID 重复调用不会重建 source。
    func watch(_ pid: pid_t) {
        guard pid > 0 else {
            stop()
            return
        }
        if source != nil && self.pid == pid { return }
        stop()

        let src = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.source?.cancel()
            self.source = nil
            self.pid = -1
            self.onExit?()
        }
        self.pid = pid
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        pid = -1
    }

    deinit {
        source?.cancel()
    }
}
