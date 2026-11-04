import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }

    /// stderr 优先，其次 stdout，去掉首尾空白，用于错误提示。
    public var diagnostic: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct CommandError: LocalizedError, Sendable {
    public let command: String
    public let result: CommandResult

    public var errorDescription: String? {
        let detail = result.diagnostic
        return "\(command) 失败（退出码 \(result.status)）" + (detail.isEmpty ? "" : "：\(detail)")
    }
}

/// 线程安全的累加缓冲，供管道读取回调使用。
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

public enum Shell {
    /// 运行一个可执行文件（不经过 shell），收集输出。
    /// - Parameters:
    ///   - stdin: 写入标准输入的数据（用于口令），写完即关闭。
    ///   - onOutput: 每收到一段 stdout 就回调（用于解析进度），可为 nil。
    ///   - onErrorOutput: 每收到一段 stderr 就回调。`diskutil image create` 的进度写在 stderr 上（实测）。
    public static func run(
        _ executable: String,
        _ arguments: [String],
        stdin: Data? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil,
        onErrorOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let outBuf = LockedBuffer()
        let errBuf = LockedBuffer()
        let group = DispatchGroup()

        group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                outBuf.append(chunk)
                if let onOutput, let text = String(data: chunk, encoding: .utf8) { onOutput(text) }
            }
        }
        group.enter()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                errBuf.append(chunk)
                if let onErrorOutput, let text = String(data: chunk, encoding: .utf8) { onErrorOutput(text) }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { proc in
                    DispatchQueue.global().async {
                        _ = group.wait(timeout: .now() + 5)
                        let result = CommandResult(
                            status: proc.terminationStatus,
                            stdout: String(decoding: outBuf.value, as: UTF8.self),
                            stderr: String(decoding: errBuf.value, as: UTF8.self)
                        )
                        cont.resume(returning: result)
                    }
                }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                    return
                }
                if let stdin, let inPipe {
                    let writer = inPipe.fileHandleForWriting
                    try? writer.write(contentsOf: stdin)
                    try? writer.close()
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }

    /// 同 `run`，但退出码非 0 时抛出 `CommandError`。
    @discardableResult
    public static func checked(
        _ executable: String,
        _ arguments: [String],
        stdin: Data? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil,
        onErrorOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let result = try await run(executable, arguments, stdin: stdin, onOutput: onOutput, onErrorOutput: onErrorOutput)
        guard result.succeeded else {
            let name = (executable as NSString).lastPathComponent
            let sub = arguments.first.map { " \($0)" } ?? ""
            throw CommandError(command: name + sub, result: result)
        }
        return result
    }
}

public enum ShellQuote {
    /// POSIX sh 单引号转义。
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
