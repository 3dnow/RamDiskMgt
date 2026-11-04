import Foundation

public enum BackupFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple Encrypted Archive：LZFSE 压缩 + AES-256，流式，体积小。
    case aea
    /// 加密 DMG（ULFO）：Finder 中输入密码即可挂载浏览。
    case dmg

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .aea: return "加密归档（.aea）"
        case .dmg: return "加密磁盘映像（.dmg）"
        }
    }

    public var summary: String {
        switch self {
        case .aea: return "AES-256 + LZFSE 压缩，写入快、体积小；可用本工具或系统 aea 命令还原。"
        case .dmg: return "AES-256 加密的压缩映像；在 Finder 中双击、输入密码就能浏览，不依赖本工具。"
        }
    }
}

public enum BackupScope: Codable, Sendable, Hashable {
    case full
    case partial([String])

    public var selection: [String]? {
        if case .partial(let paths) = self { return paths }
        return nil
    }

    public var displayName: String {
        switch self {
        case .full: return "整盘"
        case .partial(let paths): return "部分（\(paths.count) 项）"
        }
    }
}

public struct BackupRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let diskName: String
    public let profileID: UUID?
    public let backend: RamDiskBackend
    public let diskCapacity: UInt64
    public let format: BackupFormat
    public let scope: BackupScope
    public let archivePath: String
    public let archiveBytes: UInt64
    public let payloadBytes: UInt64
    public let fileCount: Int
    /// 钥匙串里存有这份备份的密码（本工具生成的备份存在 `keychainAccount(for:)` 下）。
    public var passwordInKeychain: Bool
    public var note: String?
    /// 备份完成时的附带提醒（例如密码没能存进钥匙串）。
    public var warning: String?
    /// 自动备份（定时 / 退出时）生成的记录，参与轮换清理。
    public var isAutomatic: Bool

    public var archiveURL: URL { URL(fileURLWithPath: archivePath) }

    public static func keychainAccount(for id: UUID) -> String { "backup:\(id.uuidString)" }
    public var keychainAccount: String { Self.keychainAccount(for: id) }
    public var archiveExists: Bool { FileManager.default.fileExists(atPath: archivePath) }
}

/// 备份内的一个条目（用于部分还原时挑选）。
public struct ArchiveEntry: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let size: UInt64
    public let isDirectory: Bool

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var depth: Int { path.split(separator: "/").count }
}

/// 写在 AEA 第一个条目里的清单（加密），让列目录不必解压整个归档。
struct BackupManifest: Codable, Sendable {
    var version = 1
    var diskName: String
    var createdAt: Date
    var entries: [ArchiveEntry]
}

public enum RestoreMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 合并：同名文件被备份覆盖，其余文件保留。
    case merge
    /// 替换：先清空目标卷（系统条目除外），再还原。
    case replace

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .merge: return "合并（覆盖同名文件，保留其他文件）"
        case .replace: return "替换（先清空目标，再还原）"
        }
    }
}

public struct BackupProgress: Sendable {
    public enum Phase: String, Sendable { case scanning, staging, writing, reading, restoring, verifying, finishing }
    public var phase: Phase
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var message: String

    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        return filesTotal == 0 ? 0 : min(1, Double(filesDone) / Double(filesTotal))
    }

    public var phaseName: String {
        switch phase {
        case .scanning: return "扫描"
        case .staging: return "准备"
        case .writing: return "写入备份"
        case .reading: return "读取备份"
        case .restoring: return "还原"
        case .verifying: return "校验"
        case .finishing: return "收尾"
        }
    }
}

public struct RestoreReport: Sendable {
    public var restoredFiles = 0
    public var restoredBytes: UInt64 = 0
    public var errors: [String] = []
}

public enum BackupError: LocalizedError, Sendable {
    case wrongPassword
    case passwordTooShort(Int)
    case archiveMissing(String)
    case corrupted(String)
    case notOurArchive
    case insufficientSpace(needed: UInt64, available: UInt64)
    case targetGone(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: return "密码错误，或备份文件已损坏"
        case .passwordTooShort(let n): return "密码至少需要 \(n) 个字符"
        case .archiveMissing(let p): return "备份文件不存在：\(p)"
        case .corrupted(let m): return "备份文件损坏：\(m)"
        case .notOurArchive: return "不是本工具生成的加密归档（缺少密钥参数）"
        case .insufficientSpace(let needed, let available):
            return "目标盘空间不足：还原需要约 \(ByteSize.format(needed))，目标盘可用 \(ByteSize.format(available))。请先扩容，或新建更大的盘再还原。"
        case .targetGone(let path):
            return "目标盘已不在（\(path)）。为避免把备份写到其他磁盘上，已停止还原。"
        case .failed(let m): return m
        }
    }
}
