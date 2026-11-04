import Darwin
import Foundation

/// 还原前的空间检查结果（界面与 BackupService 共用同一个算法）。
public struct RestoreCheck: Sendable, Equatable {
    public let needed: UInt64
    public let available: UInt64
    public var fits: Bool { needed <= available }
}

/// 还原所需空间的估算，以及从备份新建盘时的推荐容量。
public enum RestoreSizing {
    public static let defaultBlockSize: UInt64 = 4096
    /// 还原后至少保留的空余空间。2026-10-15 的事故里卷被写满后卸载返回 ENOSPC；
    /// 这个余量是经验值，不是从已确认的机制推出来的（见 docs/测试报告.md 2.2）。
    public static let safetyMargin: UInt64 = 16 * ByteSize.mib

    /// 还原这些条目大约要占用的空间：文件按块对齐，每个条目另计一块元数据。
    public static func requiredBytes(entries: [ArchiveEntry], selection: [String]? = nil, blockSize: UInt64 = defaultBlockSize) -> UInt64 {
        let sel = selection.map(PathSelection.init)
        let bs = max(defaultBlockSize, blockSize)
        var total: UInt64 = 0
        for e in entries {
            if let sel {
                if e.isDirectory ? !sel.shouldVisit(e.path) : !sel.contains(e.path) { continue }
            }
            total += (e.isDirectory ? 0 : ByteSize.align(e.size, to: bs)) + bs
        }
        return total
    }

    /// 新建一块能放下 `contentBytes` 的盘：内容 + 文件系统开销 + 15% 余量（至少 64MB），按 64MB 取整。
    /// tmpfs 可能按内存页（Apple Silicon 为 16KB）分配，调用方应先用页大小估算 `contentBytes`。
    public static func recommendedDiskSize(forContent contentBytes: UInt64, backend: RamDiskBackend) -> UInt64 {
        let headroom = max(64 * ByteSize.mib, contentBytes * 15 / 100)
        let raw = contentBytes + backend.overheadBytes + headroom
        return max(backend.minimumSize, ByteSize.align(raw, to: 64 * ByteSize.mib))
    }

    /// 新建某种后端的盘时用于估算的块大小。
    public static func blockSize(for backend: RamDiskBackend) -> UInt64 {
        backend == .tmpfs ? max(defaultBlockSize, UInt64(getpagesize())) : defaultBlockSize
    }

    /// 还原前的空间检查。
    /// - Parameter requireMountPoint: 目标必须仍是一个挂载点的根。盘被推出后，自定义挂载点目录还在，
    ///   statfs 会落到启动盘上，不核对就会把备份写进启动盘。
    public static func check(targetRoot: String, entries: [ArchiveEntry], selection: [String]?, mode: RestoreMode,
                             requireMountPoint: Bool) throws -> RestoreCheck {
        guard let entry = MountTable.entry(at: targetRoot) else {
            throw BackupError.targetGone(targetRoot)
        }
        if requireMountPoint, MountTable.normalize(entry.mountPoint) != MountTable.normalize(targetRoot) {
            throw BackupError.targetGone(targetRoot)
        }
        let needed = requiredBytes(entries: entries, selection: selection, blockSize: entry.blockSize) + safetyMargin
        // tmpfs 删除后要几分钟才回收（实测），不计回收空间。
        guard entry.fsType != "tmpfs" else { return RestoreCheck(needed: needed, available: entry.availableBytes) }
        let reclaim = reclaimableBytes(targetRoot: targetRoot, entries: entries, selection: selection, mode: mode)
        let (sum, overflow) = entry.availableBytes.addingReportingOverflow(reclaim)
        return RestoreCheck(needed: needed, available: overflow ? .max : sum)
    }

    /// 还原时会被删掉的文件能腾出的空间（保守估计，宁少勿多）：
    /// 只计目标卷上的普通文件；同一个 inode 只算一次；APFS 克隆只算独占部分；合并模式下多链接文件不计。
    /// APFS 覆盖同名文件时先删后写（实测剩 59.9MB 能覆盖 70MB 的文件），所以被覆盖的空间可以算上。
    static func reclaimableBytes(targetRoot: String, entries: [ArchiveEntry], selection: [String]?, mode: RestoreMode) -> UInt64 {
        var rootStat = stat()
        guard lstat(targetRoot, &rootStat) == 0 else { return 0 }
        let device = rootStat.st_dev
        var seen = Set<UInt64>()

        func freed(_ path: String, requireSingleLink: Bool) -> UInt64 {
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_dev == device else { return 0 }
            if requireSingleLink, st.st_nlink > 1 { return 0 }
            guard seen.insert(UInt64(st.st_ino)).inserted else { return 0 }
            let blocks = UInt64(st.st_blocks) * 512
            return min(blocks, CloneInfo.privateSize(atPath: path) ?? blocks)
        }

        var total: UInt64 = 0
        switch mode {
        case .merge:
            let sel = selection.map(PathSelection.init)
            for e in entries where !e.isDirectory && (sel?.contains(e.path) ?? true) {
                total += freed(targetRoot + "/" + e.path, requireSingleLink: true)
            }
        case .replace:
            guard let items = try? FileSync.scan(root: targetRoot, selection: nil) else { return 0 }
            for item in items where item.kind == .file {
                total += freed(targetRoot + "/" + item.path, requireSingleLink: false)
            }
        }
        return total
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .ENOSPC { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }
}
