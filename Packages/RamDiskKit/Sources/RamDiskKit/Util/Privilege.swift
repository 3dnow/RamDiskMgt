import Foundation

public enum PrivilegeError: LocalizedError, Sendable {
    case cancelled
    case failed(String)

    /// 用户取消了授权框，或任务被取消：都不算操作失败。
    public static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .cancelled? = error as? PrivilegeError { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消管理员授权"
        case .failed(let message): return "管理员操作失败：\(message)"
        }
    }
}

/// 以 root 身份执行一段 /bin/sh 脚本。
public protocol PrivilegedExecutor: Sendable {
    /// - Parameters:
    ///   - script: sh 脚本，内部参数需已用 `ShellQuote` 转义。
    ///   - reason: 授权对话框里显示的说明。
    /// - Returns: 脚本的标准输出（含合并的标准错误）。
    func runAsRoot(_ script: String, reason: String) async throws -> String
}

public enum PrivilegedExecutors {
    /// 当前进程已是 root 时直接执行，否则通过 osascript 弹出管理员授权框。
    public static func automatic() -> any PrivilegedExecutor {
        geteuid() == 0 ? DirectRootExecutor() : OsascriptExecutor()
    }
}

/// 进程本身已是 root（例如 `sudo rdmctl`）。
public struct DirectRootExecutor: PrivilegedExecutor {
    public init() {}

    public func runAsRoot(_ script: String, reason: String) async throws -> String {
        let result = try await Shell.run("/bin/sh", ["-c", "exec 2>&1\n" + script])
        guard result.succeeded else { throw PrivilegeError.failed(result.diagnostic) }
        return result.stdout
    }
}

enum AppleScriptSource {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func adminShell(_ script: String, reason: String) -> String {
        let wrapped = "/bin/sh -c \(ShellQuote.quote(script)) 2>&1"
        return "do shell script \"\(escape(wrapped))\" with prompt \"\(escape(reason))\" with administrator privileges without altering line endings"
    }

    static func isUserCancel(_ message: String) -> Bool {
        message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled")
    }
}

/// 每次调用都启动一个 osascript 进程，弹出系统管理员授权框。命令行和 App 都用它。
/// 脚本在子进程里执行，不占主线程；NSAppleScript 按苹果的线程安全说明只能在主线程使用，在主线程同步执行又会让界面冻结到 root 命令跑完。
/// 实测 macOS 27 上不存在“5 分钟授权缓存”，每次调用都会弹出授权框（见 docs/测试报告.md），
/// 所以调用方应把一次操作需要的 root 命令合并成一个脚本。
public final class OsascriptExecutor: PrivilegedExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(reason: String, seconds: Double)] = []

    public init() {}

    /// 本进程内的调用次数与耗时（含用户输入密码的时间）。
    public var callLog: [(reason: String, seconds: Double)] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    public func runAsRoot(_ script: String, reason: String) async throws -> String {
        let source = AppleScriptSource.adminShell(script, reason: reason)
        let start = Date()
        defer { record(reason, seconds: Date().timeIntervalSince(start)) }
        let result = try await Shell.run("/usr/bin/osascript", ["-e", source])
        guard result.succeeded else {
            if AppleScriptSource.isUserCancel(result.stderr) { throw PrivilegeError.cancelled }
            throw PrivilegeError.failed(result.diagnostic)
        }
        return result.stdout
    }

    private func record(_ reason: String, seconds: Double) {
        lock.lock(); log.append((reason, seconds)); lock.unlock()
    }
}
