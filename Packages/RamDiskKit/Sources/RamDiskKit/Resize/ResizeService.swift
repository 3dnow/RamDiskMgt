import Foundation

public struct ResizeProgress: Sendable {
    public enum Phase: Int, Sendable, CaseIterable {
        case preparing, creatingTarget, initialSync, checkingHolders, finalSync, switching, verifying, cleaningUp, done

        public var displayName: String {
            switch self {
            case .preparing: return "检查"
            case .creatingTarget: return "创建新盘"
            case .initialSync: return "第一轮同步（原盘照常使用）"
            case .checkingHolders: return "检查占用进程"
            case .finalSync: return "增量同步"
            case .switching: return "切换挂载"
            case .verifying: return "校验"
            case .cleaningUp: return "释放旧盘"
            case .done: return "完成"
            }
        }
    }

    public var phase: Phase
    public var message: String
    public var sync: SyncProgress?
}

public struct ResizeOptions: Sendable {
    /// 有进程占用时如何处理：返回 true 继续（这些进程会失去打开的文件），false 取消。
    public var confirmHolders: @Sendable ([ProcessHolder]) async -> Bool

    public init(confirmHolders: @escaping @Sendable ([ProcessHolder]) async -> Bool = { $0.isEmpty }) {
        self.confirmHolders = confirmHolders
    }
}

public struct ResizeResult: Sendable {
    public let disk: RamDisk
    public let copiedBytes: UInt64
    /// 从卸载旧盘到新盘可用的时间。
    public let switchDuration: TimeInterval
}

/// 热迁移式扩容/缩容。macOS 的 ram:// 设备与 tmpfs 都不支持原地改大小（见 docs/设计文档.md 实测），
/// 因此新建一块目标大小的盘，原盘在线时先全量同步，再短暂切换。
public actor ResizeService {
    private let manager: RamDiskManager

    public init(manager: RamDiskManager) {
        self.manager = manager
    }

    public static func check(disk: RamDisk, newSize: UInt64) throws {
        let required = disk.usedBytes + disk.backend.overheadBytes
        guard newSize >= required else {
            throw RamDiskError.invalidSize("新容量至少需要 \(ByteSize.format(required))（已用 \(ByteSize.format(disk.usedBytes)) + 文件系统开销）")
        }
        guard newSize >= disk.backend.minimumSize else {
            throw RamDiskError.invalidSize("\(disk.backend.displayName) 最小 \(ByteSize.format(disk.backend.minimumSize))")
        }
        if disk.backend == .tmpfs, newSize > MemoryInfo.tmpfsMaximum {
            throw RamDiskError.invalidSize("tmpfs 上限为物理内存的一半（\(ByteSize.format(MemoryInfo.tmpfsMaximum))）")
        }
        guard newSize <= MemoryInfo.physicalMemory else {
            throw RamDiskError.invalidSize("容量不能超过物理内存")
        }
        // 迁移期间新旧两份数据同时存在。
        let snapshot = MemoryInfo.snapshot()
        let peak = disk.usedBytes
        if peak > snapshot.available + snapshot.cachedFiles {
            throw RamDiskError.insufficientMemory(needed: peak, available: snapshot.available + snapshot.cachedFiles)
        }
    }

    public func resize(_ disk: RamDisk, to newSize: UInt64, options: ResizeOptions = ResizeOptions(),
                       progress: (@Sendable (ResizeProgress) -> Void)? = nil) async throws -> ResizeResult {
        progress?(ResizeProgress(phase: .preparing, message: "检查容量与内存"))
        try Self.check(disk: disk, newSize: newSize)
        switch disk.backend {
        case .tmpfs:
            return try await resizeTmpfs(disk, to: newSize, options: options, progress: progress)
        case .apfs, .apfsCaseSensitive, .hfsPlus:
            return try await resizeRamDevice(disk, to: newSize, options: options, progress: progress)
        }
    }

    static func stagingPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("rdm-resize-\(UUID().uuidString.prefix(8))").path
    }

    // MARK: - ram:// 设备

    private func resizeRamDevice(_ disk: RamDisk, to newSize: UInt64, options: ResizeOptions,
                                 progress: (@Sendable (ResizeProgress) -> Void)?) async throws -> ResizeResult {
        guard let oldWhole = disk.wholeDevice, let oldVolume = disk.volumeDevice else { throw RamDiskError.notFound(disk.mountPoint) }
        let staging = Self.stagingPath()

        progress?(ResizeProgress(phase: .creatingTarget, message: "创建 \(ByteSize.format(newSize)) 的新盘"))
        // 卷名与原盘一致，切换后挂到 /Volumes/<name> 时名字不变。
        let spec = DiskSpec(name: disk.name, backend: disk.backend, sizeBytes: newSize)
        let target = try await manager.createRamDevice(spec, mountAt: staging, options: MountOptions(hidden: true))
        guard let newWhole = target.wholeDevice, let newVolume = target.volumeDevice else {
            throw RamDiskError.operationFailed("新盘缺少设备信息")
        }

        var oldUnmounted = false
        /// 新盘已挂到原路径并通过校验。之后再出错（释放旧设备失败、重新查询失败）不能回滚：
        /// 回滚会把已经在用的新盘拆掉、换回旧数据，切换之后写入的内容就丢了。
        var verified = false
        do {
            let copied = try await syncTwoPhase(from: disk.mountPoint, to: target.mountPoint, options: options, progress: progress)
            let expected = try FileSync.summary(of: URL(fileURLWithPath: disk.mountPoint))

            progress?(ResizeProgress(phase: .switching, message: "卸载旧盘，新盘挂到 \(disk.mountPoint)"))
            let switchStart = Date()
            try await manager.unmountVolume(oldVolume, force: true)
            oldUnmounted = true
            try await manager.unmountVolume(newVolume, force: false)
            try await manager.mountVolume(newVolume, volumeName: disk.name, at: disk.mountPoint,
                                          options: MountOptions(hidden: disk.hidden, noExec: disk.noExec))
            let switchDuration = Date().timeIntervalSince(switchStart)

            progress?(ResizeProgress(phase: .verifying, message: "核对文件数与总字节数"))
            let actual = try FileSync.summary(of: URL(fileURLWithPath: disk.mountPoint))
            guard actual == expected else {
                throw RamDiskError.operationFailed(Self.mismatchMessage(expected: expected, actual: actual) + "已回滚到原盘，请停掉正在写入的程序后重试。")
            }
            verified = true

            progress?(ResizeProgress(phase: .cleaningUp, message: "释放旧盘内存"))
            do {
                try await manager.ejectRamDevice(oldWhole, volumeDevice: nil, force: true)
            } catch {
                // 旧设备没释放只是多占内存，新盘已经可用，不算失败。
                DiagnosticsLog.append("resize", "新盘已切换到 \(disk.mountPoint)，但释放旧设备 \(oldWhole) 失败：\(error.localizedDescription)。可手动执行 diskutil eject \(oldWhole)。")
            }
            try? FileManager.default.removeItem(atPath: staging)
            let result: RamDisk
            if let found = try? await manager.disk(at: disk.mountPoint) {
                result = found
            } else {
                // 重新枚举失败时按已知信息拼出结果，再用挂载表刷新容量。
                result = RamDisk(name: disk.name, backend: disk.backend, mountPoint: disk.mountPoint, wholeDevice: newWhole,
                                 volumeDevice: newVolume, deviceBytes: target.deviceBytes, capacityBytes: target.capacityBytes,
                                 usedBytes: target.usedBytes, availableBytes: target.availableBytes,
                                 hidden: disk.hidden, noExec: disk.noExec).refreshed()
            }
            progress?(ResizeProgress(phase: .done, message: "完成"))
            return ResizeResult(disk: result, copiedBytes: copied, switchDuration: switchDuration)
        } catch {
            if verified { throw error }
            // 回滚：卸掉新盘，把旧盘挂回原处。
            _ = try? await Shell.run("/usr/sbin/diskutil", ["unmount", "force", newVolume])
            if oldUnmounted {
                try? await manager.mountVolume(oldVolume, volumeName: disk.name, at: disk.mountPoint,
                                               options: MountOptions(hidden: disk.hidden, noExec: disk.noExec))
            }
            try? await manager.ejectRamDevice(newWhole, volumeDevice: nil, force: true)
            try? FileManager.default.removeItem(atPath: staging)
            throw error
        }
    }

    // MARK: - tmpfs

    /// tmpfs 不能换挂载点。做法：用一块不需要 root 的 ram:// APFS 盘做暂存（两轮同步），
    /// 一次提权完成“卸载原盘 + 在原路径挂新上限的 tmpfs”，再从暂存盘拷回、校验、释放暂存盘。
    /// 整个过程只需要一次管理员授权。
    private func resizeTmpfs(_ disk: RamDisk, to newSize: UInt64, options: ResizeOptions,
                             progress: (@Sendable (ResizeProgress) -> Void)?) async throws -> ResizeResult {
        let staging = Self.stagingPath()
        let mp = MountTable.normalize(disk.mountPoint)
        let uid = getuid(), gid = getgid()
        var mountOpts: [String] = []
        if disk.hidden { mountOpts.append("nobrowse") }
        if disk.noExec { mountOpts.append("noexec") }
        let optArg = mountOpts.isEmpty ? "" : " -o " + mountOpts.joined(separator: ",")

        progress?(ResizeProgress(phase: .creatingTarget, message: "创建暂存盘（ram:// APFS）"))
        // tmpfs 按页统计用量，小文件搬到 APFS 上还有每个文件的元数据开销，暂存盘按还原时的推荐容量留余量。
        let stagingSize = RestoreSizing.recommendedDiskSize(forContent: disk.usedBytes, backend: .apfs)
        let stagingDisk = try await manager.createRamDevice(
            DiskSpec(name: "RDMStaging", backend: .apfs, sizeBytes: stagingSize),
            mountAt: staging, options: MountOptions(hidden: true))
        guard let stagingWhole = stagingDisk.wholeDevice else { throw RamDiskError.operationFailed("暂存盘缺少设备信息") }

        var originalGone = false
        do {
            _ = try await syncTwoPhase(from: mp, to: stagingDisk.mountPoint, options: options, progress: progress)
            let expected = try FileSync.summary(of: URL(fileURLWithPath: mp))

            progress?(ResizeProgress(phase: .switching, message: "在 \(mp) 重新挂载 \(ByteSize.format(newSize)) 的 tmpfs"))
            let switchStart = Date()
            try await manager.runPrivileged("""
                set -e
                /sbin/umount -f \(ShellQuote.quote(mp))
                /bin/mkdir -p \(ShellQuote.quote(mp))
                /sbin/mount_tmpfs -s \(newSize)\(optArg) \(ShellQuote.quote(mp))
                /usr/sbin/chown \(uid):\(gid) \(ShellQuote.quote(mp))
                """, reason: "RamDiskMgt 需要管理员权限来切换 tmpfs 挂载（扩容到 \(ByteSize.format(newSize))）。")
            originalGone = true
            let report = try await FileSync.sync(from: URL(fileURLWithPath: stagingDisk.mountPoint), to: URL(fileURLWithPath: mp),
                                                 options: SyncOptions(mirror: true)) { p in
                progress?(ResizeProgress(phase: .switching, message: "从暂存盘拷回", sync: p))
            }
            let switchDuration = Date().timeIntervalSince(switchStart)
            guard report.errors.isEmpty else {
                throw RamDiskError.operationFailed("拷回时出错：\(report.errors.prefix(3).joined(separator: "；"))。数据仍保留在暂存盘 \(stagingDisk.mountPoint)")
            }

            progress?(ResizeProgress(phase: .verifying, message: "核对文件数与总字节数"))
            let actual = try FileSync.summary(of: URL(fileURLWithPath: mp))
            guard actual == expected else {
                throw RamDiskError.operationFailed(Self.mismatchMessage(expected: expected, actual: actual) + "数据仍保留在暂存盘 \(stagingDisk.mountPoint)")
            }

            progress?(ResizeProgress(phase: .cleaningUp, message: "释放暂存盘"))
            try await manager.ejectRamDevice(stagingWhole, volumeDevice: stagingDisk.volumeDevice, force: true)
            try? FileManager.default.removeItem(atPath: staging)
            guard let result = try await manager.disk(at: mp) else { throw RamDiskError.operationFailed("切换后找不到新盘") }
            progress?(ResizeProgress(phase: .done, message: "完成"))
            return ResizeResult(disk: result, copiedBytes: report.copiedBytes, switchDuration: switchDuration)
        } catch {
            if !originalGone {
                if Self.isTmpfsMounted(at: mp) {
                    // 原盘还在（同步出错、用户取消切换或取消授权）：直接丢弃暂存盘即可。
                    try? await manager.ejectRamDevice(stagingWhole, volumeDevice: stagingDisk.volumeDevice, force: true)
                    try? FileManager.default.removeItem(atPath: staging)
                    throw error
                }
                // 提权脚本在 umount 之后才失败（例如 mount_tmpfs 出错）：原盘已经没了，暂存盘是唯一的数据副本，绝不能丢。
                DiagnosticsLog.append("resize", "tmpfs 切换失败且原盘 \(mp) 已卸载，数据保留在暂存盘 \(stagingDisk.mountPoint)（设备 \(stagingWhole)）：\(error.localizedDescription)")
                throw RamDiskError.operationFailed("\(error.localizedDescription)\n原盘已被卸载，数据完整保留在暂存盘 \(stagingDisk.mountPoint)。请先把需要的内容拷走，再用 diskutil eject \(stagingWhole) 释放它。")
            }
            // 原盘已卸载时保留暂存盘，数据不丢，错误信息里带有暂存路径。
            throw error
        }
    }

    /// 校验失败的说明。文件数和总字节数都一样时，是有文件在最后一轮同步之后被原地改写了（修改时间对不上）。
    static func mismatchMessage(expected: TreeSummary, actual: TreeSummary) -> String {
        if expected.sameCountsAndBytes(as: actual) {
            return "校验不一致：文件数和总大小都相同，但有文件在切换前的最后一刻被改写（修改时间对不上）。"
        }
        return "校验不一致：原盘 \(expected.files) 个文件 / \(ByteSize.format(expected.bytes))，新盘 \(actual.files) 个文件 / \(ByteSize.format(actual.bytes))。"
    }

    /// `path` 现在是否仍是一个 tmpfs 挂载点的根。
    static func isTmpfsMounted(at path: String) -> Bool {
        guard let entry = MountTable.entry(at: path) else { return false }
        return entry.fsType == "tmpfs" && MountTable.normalize(entry.mountPoint) == MountTable.normalize(path)
    }

    // MARK: - 两轮同步

    private func syncTwoPhase(from source: String, to target: String, options: ResizeOptions,
                              progress: (@Sendable (ResizeProgress) -> Void)?) async throws -> UInt64 {
        let src = URL(fileURLWithPath: source), dst = URL(fileURLWithPath: target)
        let first = try await FileSync.sync(from: src, to: dst, options: SyncOptions(mirror: true)) { p in
            progress?(ResizeProgress(phase: .initialSync, message: p.currentPath, sync: p))
        }
        guard first.errors.isEmpty else {
            throw RamDiskError.operationFailed("同步出错：\(first.errors.prefix(3).joined(separator: "；"))")
        }

        progress?(ResizeProgress(phase: .checkingHolders, message: "检查是否有程序正在使用原盘"))
        let holders = await ProcessHolders.holders(of: source)
        if !holders.isEmpty {
            guard await options.confirmHolders(holders) else {
                throw RamDiskError.busy(holders)
            }
        }

        let second = try await FileSync.sync(from: src, to: dst, options: SyncOptions(mirror: true)) { p in
            progress?(ResizeProgress(phase: .finalSync, message: p.currentPath, sync: p))
        }
        guard second.errors.isEmpty else {
            throw RamDiskError.operationFailed("同步出错：\(second.errors.prefix(3).joined(separator: "；"))")
        }
        return first.copiedBytes + second.copiedBytes
    }
}
