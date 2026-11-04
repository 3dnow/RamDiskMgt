import Foundation

public enum RamDiskBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case apfs
    case apfsCaseSensitive
    case hfsPlus
    case tmpfs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apfs: return "APFS"
        case .apfsCaseSensitive: return "APFS（区分大小写）"
        case .hfsPlus: return "HFS+（日志式）"
        case .tmpfs: return "tmpfs"
        }
    }

    public var summary: String {
        switch self {
        case .apfs, .apfsCaseSensitive:
            return "基于 ram:// 设备，无需管理员密码；删除文件后立即归还内存。"
        case .hfsPlus:
            return "基于 ram:// 设备，元数据开销小，兼容老工具；无需管理员密码。"
        case .tmpfs:
            return "内核原生内存文件系统，速度最快；创建、推出、扩容都需要管理员密码；删除文件后内存延迟回收；上限为物理内存一半。"
        }
    }

    /// 是否需要管理员权限才能创建、推出。
    public var needsPrivilege: Bool { self == .tmpfs }

    public var isRamDevice: Bool { self != .tmpfs }

    /// `diskutil eraseDisk` 使用的格式名。
    var diskutilFormat: String {
        switch self {
        case .apfs: return "APFS"
        case .apfsCaseSensitive: return "APFSX"
        case .hfsPlus: return "JHFS+"
        case .tmpfs: return ""
        }
    }

    /// 文件系统元数据需要的余量，扩容/缩容时用于判断空间是否足够。
    public var overheadBytes: UInt64 {
        switch self {
        case .apfs, .apfsCaseSensitive: return 48 * ByteSize.mib
        case .hfsPlus: return 16 * ByteSize.mib
        case .tmpfs: return 4 * ByteSize.mib
        }
    }

    public var minimumSize: UInt64 {
        switch self {
        case .apfs, .apfsCaseSensitive: return 64 * ByteSize.mib
        case .hfsPlus: return 16 * ByteSize.mib
        case .tmpfs: return 1 * ByteSize.mib
        }
    }
}

public struct MountOptions: Codable, Sendable, Hashable {
    /// 不在 Finder 边栏和桌面显示（nobrowse）。
    public var hidden: Bool
    /// 禁止执行卷内的程序（noexec）。
    public var noExec: Bool
    /// 关闭 Spotlight 索引（需要管理员密码）。
    public var disableSpotlight: Bool

    public init(hidden: Bool = false, noExec: Bool = false, disableSpotlight: Bool = false) {
        self.hidden = hidden
        self.noExec = noExec
        self.disableSpotlight = disableSpotlight
    }

    var mountOptionList: [String] {
        var list: [String] = []
        if hidden { list.append("nobrowse") }
        if noExec { list.append("noexec") }
        return list
    }
}

/// 创建一块 RAM 盘所需的参数。
public struct DiskSpec: Sendable, Hashable {
    public var name: String
    public var backend: RamDiskBackend
    public var sizeBytes: UInt64
    /// nil 表示 /Volumes/<name>
    public var mountPoint: String?
    public var options: MountOptions

    public init(name: String, backend: RamDiskBackend, sizeBytes: UInt64, mountPoint: String? = nil, options: MountOptions = MountOptions()) {
        self.name = name
        self.backend = backend
        self.sizeBytes = sizeBytes
        self.mountPoint = mountPoint
        self.options = options
    }

    public var resolvedMountPoint: String { mountPoint ?? "/Volumes/\(name)" }
}

/// 一块正在运行的 RAM 盘。
public struct RamDisk: Sendable, Hashable, Identifiable {
    public var id: String { mountPoint }

    public let name: String
    public let backend: RamDiskBackend
    public let mountPoint: String
    /// ram:// 盘的整盘设备（disk11）；tmpfs 为 nil。
    public let wholeDevice: String?
    /// 实际挂载的卷设备（APFS 为 disk12s1，HFS+ 为 disk11）；tmpfs 为 nil。
    public let volumeDevice: String?
    /// ram:// 设备的大小；tmpfs 为挂载时设定的上限。
    public let deviceBytes: UInt64
    public let capacityBytes: UInt64
    public let usedBytes: UInt64
    public let availableBytes: UInt64
    public let hidden: Bool
    public let noExec: Bool

    public var usedFraction: Double {
        capacityBytes == 0 ? 0 : min(1, Double(usedBytes) / Double(capacityBytes))
    }

    public init(name: String, backend: RamDiskBackend, mountPoint: String, wholeDevice: String?, volumeDevice: String?,
                deviceBytes: UInt64, capacityBytes: UInt64, usedBytes: UInt64, availableBytes: UInt64, hidden: Bool, noExec: Bool) {
        self.name = name
        self.backend = backend
        self.mountPoint = mountPoint
        self.wholeDevice = wholeDevice
        self.volumeDevice = volumeDevice
        self.deviceBytes = deviceBytes
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.hidden = hidden
        self.noExec = noExec
    }

    public var options: MountOptions { MountOptions(hidden: hidden, noExec: noExec) }

    /// 用当前挂载统计刷新容量数据。
    public func refreshed() -> RamDisk {
        // 卸载的瞬间 statfs 会落到上一级目录所在的文件系统，必须核对挂载点。
        guard let entry = MountTable.entry(at: mountPoint),
              MountTable.normalize(entry.mountPoint) == MountTable.normalize(mountPoint) else { return self }
        return RamDisk(name: name, backend: backend, mountPoint: mountPoint, wholeDevice: wholeDevice, volumeDevice: volumeDevice,
                       deviceBytes: deviceBytes, capacityBytes: entry.totalBytes, usedBytes: entry.usedBytes,
                       availableBytes: entry.availableBytes, hidden: entry.isHidden, noExec: entry.isNoExec)
    }
}

public enum RamDiskError: LocalizedError, Sendable {
    case invalidName(String)
    case invalidSize(String)
    case invalidMountPoint(String)
    case alreadyMounted(String)
    case notFound(String)
    case busy([ProcessHolder])
    case insufficientMemory(needed: UInt64, available: UInt64)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let m), .invalidSize(let m), .invalidMountPoint(let m), .operationFailed(let m):
            return m
        case .alreadyMounted(let p):
            return "\(p) 已经挂载了其他卷"
        case .notFound(let p):
            return "找不到 RAM 盘：\(p)"
        case .busy(let holders):
            let names = holders.map { "\($0.command)(\($0.pid))" }.joined(separator: "、")
            return "卷正被使用：\(names)"
        case .insufficientMemory(let needed, let available):
            return "内存不足：需要约 \(ByteSize.format(needed))，当前可用约 \(ByteSize.format(available))"
        }
    }
}

/// 卷根目录下由系统维护的条目，复制、备份、分析时特殊处理。
public enum VolumeSpecialItems {
    public static let names: Set<String> = [
        ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
        ".metadata_never_index", ".VolumeIcon.icns", ".com.apple.timemachine.donotpresent",
    ]
    /// 本应用在卷内创建的临时目录前缀。
    public static let appPrefix = ".rdm-"

    public static func isSpecial(rootLevelName name: String) -> Bool {
        names.contains(name) || name.hasPrefix(appPrefix)
    }

    /// 相对路径（相对卷根）是否属于系统条目或其子项。
    public static func isSpecial(relativePath path: String) -> Bool {
        let first = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        return isSpecial(rootLevelName: first)
    }
}
