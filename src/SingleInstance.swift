// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

// MARK: - 单实例

/// 同一用户只允许一个 GUI 实例。用 flock 持有实例锁：进程退出或崩溃时内核自动释放，
/// 不会留下需要手工清理的陈旧锁。返回 false 表示已有实例在跑。
func acquireInstanceLock() -> Bool {
    let dir = ProfileStore.dir.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("instance.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }  // 锁文件不可写时不要因此拒绝启动
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return false
    }
    // 故意不关闭 fd：锁要一直持有到进程退出。顺便写入 pid 便于排障。
    ftruncate(fd, 0)
    let pidLine = "\(getpid())\n"
    _ = pidLine.withCString { write(fd, $0, strlen($0)) }
    return true
}
