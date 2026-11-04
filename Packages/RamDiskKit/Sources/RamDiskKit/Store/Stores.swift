import Foundation
import Security

public enum AppPaths {
    /// 应用数据目录；可用环境变量 RDM_SUPPORT_DIR 覆盖（测试用）。
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["RDM_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RamDiskMgt", isDirectory: true)
    }

    public static var defaultBackupDirectory: URL {
        supportDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 简单的 JSON 文件存储。
struct JSONFile<Value: Codable & Sendable>: Sendable {
    let url: URL

    func load(default value: Value) -> Value {
        guard let data = try? Data(contentsOf: url) else { return value }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            // 文件损坏，或是更新版本写的格式：不能悄悄按空列表处理——下一次保存就会把原文件覆盖掉，
            // 所有盘配置 / 备份清单就此丢失。改名留档并记日志，让用户有机会找回。
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            DiagnosticsLog.append("store", "无法读取 \(url.lastPathComponent)：\(error)\n原文件已改名为 \(aside.lastPathComponent)，本次按空列表启动。")
            return value
        }
    }

    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

// MARK: - 磁盘配置

public struct AutosavePolicy: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var intervalMinutes: Int
    public var onQuit: Bool
    public var keepCount: Int
    public var format: BackupFormat

    public init(enabled: Bool = false, intervalMinutes: Int = 30, onQuit: Bool = true, keepCount: Int = 5, format: BackupFormat = .aea) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.onQuit = onQuit
        self.keepCount = keepCount
        self.format = format
    }
}

/// 一块 RAM 盘的持久化配置，用于重建。
public struct DiskProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var backend: RamDiskBackend
    public var sizeBytes: UInt64
    public var customMountPoint: String?
    public var options: MountOptions
    /// 应用启动时若未挂载则自动创建。
    public var autoCreate: Bool
    /// 创建后自动还原最近一次备份（需要钥匙串里保存了密码）。
    public var restoreLatestOnCreate: Bool
    public var autosave: AutosavePolicy
    public var backupDirectory: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, backend: RamDiskBackend, sizeBytes: UInt64, customMountPoint: String? = nil,
                options: MountOptions = MountOptions(), autoCreate: Bool = false, restoreLatestOnCreate: Bool = false,
                autosave: AutosavePolicy = AutosavePolicy(), backupDirectory: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.backend = backend
        self.sizeBytes = sizeBytes
        self.customMountPoint = customMountPoint
        self.options = options
        self.autoCreate = autoCreate
        self.restoreLatestOnCreate = restoreLatestOnCreate
        self.autosave = autosave
        self.backupDirectory = backupDirectory
        self.createdAt = createdAt
    }

    public var mountPoint: String { customMountPoint ?? "/Volumes/\(name)" }

    public var spec: DiskSpec {
        DiskSpec(name: name, backend: backend, sizeBytes: sizeBytes, mountPoint: customMountPoint, options: options)
    }

    public var backupDirectoryURL: URL {
        backupDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppPaths.defaultBackupDirectory
    }

    public var keychainAccount: String { "profile:\(id.uuidString)" }
}

public actor ProfileStore {
    private let file: JSONFile<[DiskProfile]>
    private var profiles: [DiskProfile]

    public init(directory: URL = AppPaths.supportDirectory) {
        file = JSONFile(url: directory.appendingPathComponent("profiles.json"))
        profiles = file.load(default: [])
    }

    public func all() -> [DiskProfile] { profiles }

    public func profile(id: UUID) -> DiskProfile? { profiles.first { $0.id == id } }

    public func profile(forMountPoint mountPoint: String) -> DiskProfile? {
        let normalized = MountTable.normalize(mountPoint)
        return profiles.first { MountTable.normalize($0.mountPoint) == normalized }
    }

    public func upsert(_ profile: DiskProfile) throws {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try file.save(profiles)
    }

    public func remove(id: UUID) throws {
        profiles.removeAll { $0.id == id }
        try file.save(profiles)
    }
}

// MARK: - 备份清单

public actor BackupCatalog {
    private let file: JSONFile<[BackupRecord]>
    private var records: [BackupRecord]

    public init(directory: URL = AppPaths.supportDirectory) {
        file = JSONFile(url: directory.appendingPathComponent("backups.json"))
        records = file.load(default: [])
    }

    public func all() -> [BackupRecord] { records.sorted { $0.createdAt > $1.createdAt } }

    public func record(id: UUID) -> BackupRecord? { records.first { $0.id == id } }

    public func records(forProfile id: UUID?, diskName: String) -> [BackupRecord] {
        all().filter { record in
            if let id, let pid = record.profileID { return pid == id }
            return record.diskName == diskName
        }
    }

    public func add(_ record: BackupRecord) throws {
        records.append(record)
        try file.save(records)
    }

    public func update(_ record: BackupRecord) throws {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        try file.save(records)
    }

    public func remove(id: UUID) throws {
        records.removeAll { $0.id == id }
        try file.save(records)
    }
}

// MARK: - 钥匙串

public enum KeychainStore {
    /// 测试用环境变量 RDM_KEYCHAIN_SERVICE 换一个服务名，避免写进真实的钥匙串条目。
    static var service: String {
        let override = ProcessInfo.processInfo.environment["RDM_KEYCHAIN_SERVICE"] ?? ""
        return override.isEmpty ? "RamDiskMgt" : override
    }

    public static func save(_ password: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "RamDiskMgt 备份密码"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BackupError.failed("保存到钥匙串失败（\(status)）")
        }
    }

    public static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
