import Foundation

/// 追加写入诊断日志：~/Library/Application Support/RamDiskMgt/logs/<name>.log
public enum DiagnosticsLog {
    public static var directory: URL { AppPaths.supportDirectory.appendingPathComponent("logs", isDirectory: true) }

    public static func append(_ name: String, _ text: String) {
        let url = directory.appendingPathComponent("\(name).log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = "=== \(ISO8601DateFormatter().string(from: Date()))\n\(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }
}
