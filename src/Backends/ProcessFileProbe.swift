import Darwin
import Foundation

/// pidfile + 就绪标记的通用探测。pidfile 里是 root 包装脚本的 PID；`kill(0)` 做存活检查，
/// `sysctl` 读启动时间识别 PID 复用，`ps` 只在首次见到某个进程实例时校验一次命令行。
///
/// 缓存状态只在主线程读写（不设锁）。
final class ProcessFileProbe {
    struct Config {
        let pidFile: String
        let readyFile: String
        /// ps 命令行里必须包含的子串，用来排除 PID 复用后的无关进程。
        let commandMarker: String
    }

    private let config: Config
    private var verifiedPID: pid_t = -1
    private var verifiedStart: UInt64?
    private var verifiedAlive = false

    init(config: Config) {
        self.config = config
    }

    func currentPID() -> pid_t? {
        guard let text = try? String(contentsOfFile: config.pidFile, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else { return nil }
        return value
    }

    /// 只做存在性检查（可在后台线程调用）。root 进程对普通用户执行 kill(0) 会返回
    /// EPERM，同样说明进程还活着；ESRCH 才是真的没了。
    func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// 读进程启动时间（微秒），用于区分「同一个 PID 的不同进程实例」。
    /// sysctl 对 root 进程也可读；读取失败时返回 nil，退化为只按 PID 缓存。
    private func processStartTime(_ pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let r = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard r == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        return UInt64(info.kp_proc.p_starttime.tv_sec) * 1_000_000
            + UInt64(info.kp_proc.p_starttime.tv_usec)
    }

    /// 存活时返回包装脚本 PID、否则返回 nil。稳态下不启动任何子进程：
    /// - `kill(pid, 0)` 每次轮询都做（系统调用，成本可忽略）；
    /// - 只有首次见到某个 PID、或启动时间变了（PID 被复用）时，才用一次 `ps` 校验命令行。
    /// 只在主线程调用（缓存不设锁）。
    func alivePID() -> pid_t? {
        guard let pid = currentPID(), processExists(pid) else {
            verifiedPID = -1
            verifiedStart = nil
            verifiedAlive = false
            return nil
        }
        let start = processStartTime(pid)
        if pid == verifiedPID && start == verifiedStart {
            return verifiedAlive ? pid : nil
        }

        // -ww：不按终端宽度截断命令行
        let (code, out) = run("/bin/ps", ["-ww", "-p", "\(pid)", "-o", "command="])
        guard code == 0 else { return nil }  // ps 自身失败：不写缓存，下个 tick 重试
        verifiedPID = pid
        verifiedStart = start
        verifiedAlive = out.contains(config.commandMarker)
        return verifiedAlive ? pid : nil
    }

    /// 就绪标记由包装脚本在隧道可用后写入，内容是「包装脚本 PID 子进程 PID」。
    /// 只有标记里的 PID 和当前 pidfile 一致，才算这次连接已经可用。
    func tunnelReady(_ pid: pid_t) -> Bool {
        guard let text = try? String(contentsOfFile: config.readyFile, encoding: .utf8) else { return false }
        let first = text.split(whereSeparator: { $0.isWhitespace }).first
        return first.map(String.init) == String(pid)
    }

    /// 只判断 pidfile 指向的进程是否还在（不校验命令行、不要求就绪）。
    func processPresent() -> Bool {
        guard let pid = currentPID() else { return false }
        return processExists(pid)
    }

    /// 就绪校验：进程存在 + 就绪标记匹配。只读文件和系统调用，可在后台线程调用。
    func readyVerified() -> Bool {
        guard let pid = currentPID(), processExists(pid) else { return false }
        return tunnelReady(pid)
    }
}
