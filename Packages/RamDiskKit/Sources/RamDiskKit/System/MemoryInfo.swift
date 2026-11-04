import Darwin
import Foundation

public enum MemoryPressure: String, Sendable {
    case normal, warning, critical

    public var displayName: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        }
    }
}

public struct MemorySnapshot: Sendable, Hashable {
    public let physical: UInt64
    public let free: UInt64
    public let appMemory: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cachedFiles: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let pressure: MemoryPressure

    /// 与“活动监视器”的“已使用内存”口径一致：App 内存 + 联动 + 压缩。
    public var used: UInt64 { appMemory + wired + compressed }
    public var available: UInt64 { physical > used ? physical - used : 0 }
    public var usedFraction: Double { physical == 0 ? 0 : Double(used) / Double(physical) }
}

public enum MemoryInfo {
    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// macOS 的 tmpfs 上限为物理内存的一半（实测 `-s 1t` 被截到 64GB / 128GB）。
    public static var tmpfsMaximum: UInt64 { physicalMemory / 2 }

    public static func snapshot() -> MemorySnapshot {
        let pageSize = UInt64(getpagesize())
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let physical = physicalMemory
        guard kr == KERN_SUCCESS else {
            return MemorySnapshot(physical: physical, free: 0, appMemory: 0, wired: 0, compressed: 0,
                                  cachedFiles: 0, swapUsed: 0, swapTotal: 0, pressure: pressure())
        }
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? (internalPages - purgeable) * pageSize : 0
        let swap = swapUsage()
        return MemorySnapshot(
            physical: physical,
            free: UInt64(stats.free_count) * pageSize,
            appMemory: app,
            wired: UInt64(stats.wire_count) * pageSize,
            compressed: UInt64(stats.compressor_page_count) * pageSize,
            cachedFiles: (UInt64(stats.external_page_count) + purgeable) * pageSize,
            swapUsed: swap.used,
            swapTotal: swap.total,
            pressure: pressure()
        )
    }

    static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4...: return .critical
        case 2...: return .warning
        default: return .normal
        }
    }

    static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }
}
