import Foundation

public struct BackupRequest: Sendable {
    public var sourceRoot: String
    public var diskName: String
    public var backend: RamDiskBackend
    public var diskCapacity: UInt64
    public var profileID: UUID?
    public var scope: BackupScope
    public var format: BackupFormat
    public var password: String
    public var destinationDirectory: URL
    /// 把密码存进钥匙串：总是存一份这次备份专用的（backup:<id>），保证以后还原能找到对的密码。
    public var rememberPassword: Bool
    /// 另外再存到这个账户（例如盘的配置账户，供自动备份使用）。
    public var saveToKeychainAccount: String?
    public var isAutomatic: Bool
    public var note: String?

    public init(disk: RamDisk, profileID: UUID?, scope: BackupScope, format: BackupFormat, password: String,
                destinationDirectory: URL, rememberPassword: Bool = false, saveToKeychainAccount: String? = nil,
                isAutomatic: Bool = false, note: String? = nil) {
        sourceRoot = disk.mountPoint
        diskName = disk.name
        backend = disk.backend
        diskCapacity = disk.capacityBytes
        self.profileID = profileID
        self.scope = scope
        self.format = format
        self.password = password
        self.destinationDirectory = destinationDirectory
        self.rememberPassword = rememberPassword || saveToKeychainAccount != nil
        self.saveToKeychainAccount = saveToKeychainAccount
        self.isAutomatic = isAutomatic
        self.note = note
    }
}

public actor BackupService {
    public let catalog: BackupCatalog

    public init(catalog: BackupCatalog) {
        self.catalog = catalog
    }

    // MARK: - 备份

    public func create(_ request: BackupRequest, progress: (@Sendable (BackupProgress) -> Void)? = nil) async throws -> BackupRecord {
        try PasswordPolicy.validate(request.password)
        if case .partial(let paths) = request.scope, paths.isEmpty {
            throw BackupError.failed("部分备份至少要选择一项")
        }
        let directory = try AppPaths.ensure(request.destinationDirectory)
        let destination = Self.uniqueDestination(in: directory, fileName: Self.fileName(for: request))
        let selection = request.scope.selection.map(PathSelection.init)

        let payload: UInt64
        let fileCount: Int
        do {
            switch request.format {
            case .aea:
                let result = try await Task.detached(priority: .userInitiated) {
                    try AEAEngine.create(sourceRoot: request.sourceRoot, selection: selection, destination: destination,
                                         password: request.password, diskName: request.diskName, progress: progress)
                }.value
                payload = result.payloadBytes
                fileCount = result.fileCount
            case .dmg:
                let result = try await DMGEngine.create(sourceRoot: request.sourceRoot, selection: selection, destination: destination,
                                                        password: request.password, volumeName: request.diskName, progress: progress)
                payload = result.payloadBytes
                fileCount = result.fileCount
            }
        } catch {
            try? FileManager.default.removeItem(atPath: destination)
            throw error
        }

        // 备份文件已经写好：存钥匙串失败不能让整次备份算作失败（原来会留下一个没登记的备份文件）。
        let id = UUID()
        var inKeychain = false
        var warning: String?
        if request.rememberPassword {
            do {
                try KeychainStore.save(request.password, account: BackupRecord.keychainAccount(for: id))
                if let extra = request.saveToKeychainAccount {
                    try KeychainStore.save(request.password, account: extra)
                }
                inKeychain = true
            } catch {
                warning = "备份已完成，但密码没能存进钥匙串（\(error.localizedDescription)）。还原时需要手动输入密码。"
                DiagnosticsLog.append("keychain", "保存备份密码失败：\(error.localizedDescription)")
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination)[.size] as? NSNumber)?.uint64Value ?? 0
        var record = BackupRecord(
            id: id, createdAt: Date(), diskName: request.diskName, profileID: request.profileID,
            backend: request.backend, diskCapacity: request.diskCapacity, format: request.format, scope: request.scope,
            archivePath: destination, archiveBytes: size, payloadBytes: payload, fileCount: fileCount,
            passwordInKeychain: inKeychain, note: request.note, isAutomatic: request.isAutomatic
        )
        record.warning = warning
        do {
            try await catalog.add(record)
        } catch {
            throw BackupError.failed("备份文件已写到 \(destination)，但登记到备份库失败：\(error.localizedDescription)。可以用“导入备份文件”把它加回来。")
        }
        progress?(BackupProgress(phase: .finishing, filesDone: fileCount, filesTotal: fileCount, bytesDone: payload,
                                 bytesTotal: payload, message: "完成"))
        return record
    }

    static func fileName(for request: BackupRequest) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = request.diskName.replacingOccurrences(of: " ", with: "_")
        var name = "\(safeName)-\(formatter.string(from: Date()))"
        if case .partial = request.scope { name += "-partial" }
        if request.isAutomatic { name += "-auto" }
        return name + "." + request.format.fileExtension
    }

    /// 文件名精确到秒：同一秒内的两次备份（例如手动备份撞上定时备份）会算出同一个名字。
    /// 已存在时加序号，否则后一份会覆盖前一份，且两条记录指向同一个文件，删除其中一条会把另一条的文件也移走。
    static func uniqueDestination(in directory: URL, fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName).path
        var index = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = directory.appendingPathComponent("\(base)-\(index).\(ext)").path
            index += 1
        }
        return candidate
    }

    // MARK: - 查看 / 校验

    public func contents(of record: BackupRecord, password: String) async throws -> [ArchiveEntry] {
        switch record.format {
        case .aea:
            return try await Task.detached { try AEAEngine.listContents(path: record.archivePath, password: password) }.value
        case .dmg:
            return try await DMGEngine.listContents(path: record.archivePath, password: password)
        }
    }

    /// 完整读一遍备份，返回其中的文件数。
    public func verify(_ record: BackupRecord, password: String) async throws -> Int {
        switch record.format {
        case .aea:
            return try await Task.detached { try AEAEngine.verify(path: record.archivePath, password: password) }.value
        case .dmg:
            return try await DMGEngine.verify(path: record.archivePath, password: password)
        }
    }

    // MARK: - 还原

    /// 还原备份。
    /// - Parameters:
    ///   - knownEntries: 调用方刚读过的内容（重建时用），避免 DMG 再挂载一次；不会跳过密码校验——
    ///     合并模式下引擎打开归档时就会校验，替换模式下清空目标之前会先完整校验。
    ///   - requireMountPoint: 目标必须仍是挂载点的根（App 里总是 true，防止盘被推出后写进启动盘）。
    public func restore(
        _ record: BackupRecord,
        password: String,
        to targetRoot: String,
        selection: [String]? = nil,
        mode: RestoreMode = .merge,
        knownEntries: [ArchiveEntry]? = nil,
        requireMountPoint: Bool = false,
        progress: (@Sendable (BackupProgress) -> Void)? = nil
    ) async throws -> RestoreReport {
        guard record.archiveExists else { throw BackupError.archiveMissing(record.archivePath) }

        // 1. 读内容（验证密码）并检查空间，任何问题都在动目标卷之前报出来。
        let entries: [ArchiveEntry]
        if let knownEntries {
            entries = knownEntries
        } else {
            entries = try await contents(of: record, password: password)
        }
        _ = try? await refreshStats(of: record, entries: entries)
        let check = try RestoreSizing.check(targetRoot: targetRoot, entries: entries, selection: selection, mode: mode,
                                            requireMountPoint: requireMountPoint)
        guard check.fits else {
            throw BackupError.insufficientSpace(needed: check.needed, available: check.available)
        }

        // 2. 还原期间一直开着目标根目录：普通推出（例如在 Finder 里）会因“正在使用”失败，
        //    不会出现“盘被推出、后续写入落到挂载点目录所在的启动盘上”。
        let guardFD = open(targetRoot, O_RDONLY | O_DIRECTORY)
        defer { if guardFD >= 0 { close(guardFD) } }

        let selected = selection.map(PathSelection.init)
        let relevant = entries.filter { !$0.isDirectory && (selected?.contains($0.path) ?? true) }
        var sizes: [String: UInt64] = [:]
        for e in relevant { sizes[e.path] = e.size }
        let totals = (files: relevant.count, bytes: relevant.reduce(UInt64(0)) { $0 + $1.size }, sizes: sizes)

        do {
            switch record.format {
            case .aea:
                if mode == .replace {
                    // 替换会先清空目标：先完整解密、解压一遍，确认归档没有损坏再动手。
                    progress?(BackupProgress(phase: .verifying, filesDone: 0, filesTotal: totals.files, bytesDone: 0,
                                             bytesTotal: totals.bytes, message: "清空目标前先完整校验备份"))
                    _ = try await Task.detached { try AEAEngine.verify(path: record.archivePath, password: password) }.value
                    try Self.clearVolume(targetRoot)
                }
                return try await Task.detached(priority: .userInitiated) {
                    try AEAEngine.restore(path: record.archivePath, password: password, to: targetRoot,
                                          selection: selected, totals: totals, progress: progress)
                }.value
            case .dmg:
                // 替换时在映像挂载成功之后才清空，并复用这一次挂载。
                return try await DMGEngine.restore(path: record.archivePath, password: password, to: targetRoot,
                                                   selection: selection,
                                                   beforeCopy: mode == .replace ? { try Self.clearVolume(targetRoot) } : nil,
                                                   progress: progress)
            }
        } catch BackupError.insufficientSpace(_, let available) {
            throw BackupError.insufficientSpace(needed: check.needed, available: available)
        }
    }

    /// 导入的备份不知道内容大小；读过一次内容后把文件数和大小记回清单。
    @discardableResult
    public func refreshStats(of record: BackupRecord, entries: [ArchiveEntry]) async throws -> BackupRecord {
        guard record.payloadBytes == 0 || record.fileCount == 0 else { return record }
        let files = entries.filter { !$0.isDirectory }
        let updated = BackupRecord(
            id: record.id, createdAt: record.createdAt, diskName: record.diskName, profileID: record.profileID,
            backend: record.backend, diskCapacity: record.diskCapacity, format: record.format, scope: record.scope,
            archivePath: record.archivePath, archiveBytes: record.archiveBytes,
            payloadBytes: files.reduce(0) { $0 + $1.size }, fileCount: files.count,
            passwordInKeychain: record.passwordInKeychain, note: record.note, isAutomatic: record.isAutomatic)
        try await catalog.update(updated)
        return updated
    }

    /// 清空卷根下的用户内容（保留系统条目），用于“替换”式还原。
    static func clearVolume(_ root: String) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: root) where !VolumeSpecialItems.isSpecial(rootLevelName: name) {
            try fm.removeItem(atPath: root + "/" + name)
        }
    }

    // MARK: - 管理

    /// 删除备份：文件移到废纸篓，并从清单中移除。
    /// - Parameter moveToTrash: false 时直接删除（测试用，避免往用户的废纸篓里放文件）。
    public func delete(_ record: BackupRecord, moveToTrash: Bool = true) async throws {
        if record.archiveExists {
            if moveToTrash {
                try FileManager.default.trashItem(at: record.archiveURL, resultingItemURL: nil)
            } else {
                try FileManager.default.removeItem(at: record.archiveURL)
            }
        }
        KeychainStore.delete(account: record.keychainAccount)
        try await catalog.remove(id: record.id)
    }

    /// 自动备份只保留最近 `keep` 份。
    public func pruneAutomatic(profileID: UUID?, diskName: String, keep: Int) async throws {
        let autos = await catalog.records(forProfile: profileID, diskName: diskName).filter(\.isAutomatic)
        guard autos.count > keep else { return }
        for record in autos.dropFirst(max(0, keep)) {
            try await delete(record)
        }
    }

    /// 把外部的 .aea / .dmg 文件登记到备份库（例如重装系统后）。
    public func importArchive(at url: URL, diskName: String? = nil) async throws -> BackupRecord {
        guard let format = BackupFormat(rawValue: url.pathExtension.lowercased()) else {
            throw BackupError.failed("只支持 .aea 或 .dmg 文件")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let record = BackupRecord(
            id: UUID(), createdAt: attrs[.creationDate] as? Date ?? Date(),
            diskName: diskName ?? url.deletingPathExtension().lastPathComponent.components(separatedBy: "-").first ?? "RAMDisk",
            profileID: nil, backend: .apfs, diskCapacity: 0, format: format, scope: .full,
            archivePath: url.path, archiveBytes: (attrs[.size] as? NSNumber)?.uint64Value ?? 0, payloadBytes: 0, fileCount: 0,
            passwordInKeychain: false, note: "导入", isAutomatic: false
        )
        try await catalog.add(record)
        return record
    }
}
