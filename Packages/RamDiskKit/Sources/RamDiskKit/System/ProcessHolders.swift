import Foundation

/// 正在使用某个卷上文件的进程。
public struct ProcessHolder: Sendable, Hashable, Identifiable {
    public let pid: Int32
    public let command: String
    public let files: [String]

    public var id: Int32 { pid }
}

public enum ProcessHolders {
    /// 系统守护进程，卸载 RAM 盘时总会出现，不需要提示用户。
    public static let ignoredCommands: Set<String> = ["fseventsd", "mds", "mds_stores", "mdworker", "mdworker_shared", "revisiond", "lsof"]

    /// 列出在 `mountPoint` 所在文件系统上打开了文件的进程（只看得到当前用户有权限看到的进程）。
    public static func holders(of mountPoint: String, includeSystem: Bool = false) async -> [ProcessHolder] {
        guard let result = try? await Shell.run("/usr/sbin/lsof", ["-Fpcn", "+f", "--", mountPoint]) else { return [] }
        return parse(result.stdout).filter { includeSystem || !ignoredCommands.contains($0.command) }
    }

    static func parse(_ output: String) -> [ProcessHolder] {
        var holders: [ProcessHolder] = []
        var pid: Int32?
        var command = ""
        var files: [String] = []

        func flush() {
            if let pid { holders.append(ProcessHolder(pid: pid, command: command, files: files)) }
            pid = nil; command = ""; files = []
        }

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                pid = Int32(value)
            case "c":
                command = value
            case "n":
                if !files.contains(value) { files.append(value) }
            default:
                break
            }
        }
        flush()
        return holders.filter { $0.pid != getpid() }
    }
}
