// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// 追加一行到 ~/Library/Logs/VPNMenu.log。
func logLine(_ s: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("VPNMenu.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let data = line.data(using: .utf8) {
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }
}
