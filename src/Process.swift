// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// 同步执行外部命令，stdout / stderr 合并返回。
@discardableResult
func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// 通过 stdin 向子进程输入数据（密码不经过 argv，不会出现在进程列表里）
@discardableResult
func runWithInput(_ launchPath: String, _ args: [String], _ input: String) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe()
    let inp = Pipe()
    p.standardOutput = out
    p.standardError = out
    p.standardInput = inp
    do { try p.run() } catch { return (-1, "\(error)") }
    inp.fileHandleForWriting.write(Data(input.utf8))
    try? inp.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
