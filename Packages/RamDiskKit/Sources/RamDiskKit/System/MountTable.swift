import Darwin
import Foundation

public struct MountEntry: Sendable, Hashable {
    public let fsType: String
    public let mountPoint: String
    public let source: String
    public let flags: UInt32
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let availableBytes: UInt64
    public let totalFiles: UInt64
    public let freeFiles: UInt64
    /// 文件系统的分配块大小（APFS 4KB；tmpfs 可能是内存页大小）。
    public let blockSize: UInt64

    public var usedBytes: UInt64 { totalBytes >= freeBytes ? totalBytes - freeBytes : 0 }
    public var isHidden: Bool { flags & UInt32(MNT_DONTBROWSE) != 0 }
    public var isNoExec: Bool { flags & UInt32(MNT_NOEXEC) != 0 }
    public var isReadOnly: Bool { flags & UInt32(MNT_RDONLY) != 0 }
    public var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }

    /// `/dev/disk12s1` → `disk12s1`
    public var bsdName: String? {
        source.hasPrefix("/dev/") ? String(source.dropFirst(5)) : nil
    }

    init(_ s: statfs) {
        var copy = s
        fsType = withUnsafeBytes(of: &copy.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        mountPoint = withUnsafeBytes(of: &copy.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        source = withUnsafeBytes(of: &copy.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        flags = s.f_flags
        let bsize = UInt64(s.f_bsize)
        blockSize = bsize
        totalBytes = UInt64(s.f_blocks) * bsize
        freeBytes = UInt64(s.f_bfree) * bsize
        availableBytes = UInt64(s.f_bavail) * bsize
        totalFiles = UInt64(s.f_files)
        freeFiles = UInt64(s.f_ffree)
    }
}

public enum MountTable {
    /// 当前所有挂载点（不阻塞等待网络卷）。
    public static func current() -> [MountEntry] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = Array<statfs>(repeating: statfs(), count: Int(count) + 8)
        let size = Int32(MemoryLayout<statfs>.stride * buffer.count)
        let filled = buffer.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, size, MNT_NOWAIT) }
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled)).map(MountEntry.init)
    }

    /// 挂载表的快速指纹（一次 getfsstat 系统调用）。没变化就说明没有新挂载或卸载的卷，不必再跑 hdiutil 枚举设备。
    public static func signature() -> Set<String> {
        Set(current().map { "\($0.fsType)|\($0.source)|\($0.mountPoint)" })
    }

    /// 某个路径所在文件系统的实时统计。
    public static func entry(at path: String) -> MountEntry? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return MountEntry(s)
    }

    public static func isMountPoint(_ path: String) -> Bool {
        let normalized = normalize(path)
        return current().contains { normalize($0.mountPoint) == normalized }
    }

    /// 去掉末尾斜杠，并把 /tmp、/var 统一成 /private 下的真实路径。
    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        for prefix in ["/tmp", "/var", "/etc"] where p == prefix || p.hasPrefix(prefix + "/") {
            p = "/private" + p
        }
        return p
    }
}
