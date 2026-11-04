import AppleArchive
import CryptoKit
import Foundation
import System

/// 根据 encodeWriting 消息估算写入进度：每个文件按“已写块数 × 256KB”累计，不超过文件大小；回调最多每 0.1 秒一次。
final class WriteTracker: @unchecked Sendable {
    static let chunkSize: UInt64 = 256 * 1024
    /// 回调最小间隔；测试里设为 0 以检查每一块都被统计到。
    nonisolated(unsafe) static var minReportInterval: TimeInterval = 0.1
    private let lock = NSLock()
    private let sizes: [String: UInt64]
    private let totalBytes: UInt64
    private let totalFiles: Int
    private let progress: (@Sendable (BackupProgress) -> Void)?
    private var chunks: [String: UInt64] = [:]
    private var bytes: UInt64 = 0
    private var lastReport = Date.distantPast

    init(sizes: [String: UInt64], totalBytes: UInt64, totalFiles: Int, progress: (@Sendable (BackupProgress) -> Void)?) {
        self.sizes = sizes
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.progress = progress
    }

    func chunkWritten(_ path: String) {
        lock.lock()
        let size = sizes[path] ?? 0
        let before = min(size, (chunks[path] ?? 0) * Self.chunkSize)
        chunks[path, default: 0] += 1
        let after = min(size, chunks[path]! * Self.chunkSize)
        bytes += after - before
        let now = Date()
        let shouldReport = now.timeIntervalSince(lastReport) >= Self.minReportInterval
        if shouldReport { lastReport = now }
        let snapshot = (bytes, chunks.count)
        lock.unlock()
        if shouldReport {
            progress?(BackupProgress(phase: .writing, filesDone: min(snapshot.1, totalFiles), filesTotal: totalFiles,
                                     bytesDone: snapshot.0, bytesTotal: totalBytes, message: path))
        }
    }
}

/// 线程安全计数器（AppleArchive 的回调可能在多个线程上执行）。
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var files = 0
    private(set) var bytes: UInt64 = 0

    func add(files f: Int = 1, bytes b: UInt64) -> (Int, UInt64) {
        lock.lock(); defer { lock.unlock() }
        files += f
        bytes += b
        return (files, bytes)
    }
}

/// 读写 Apple Encrypted Archive 备份。
enum AEAEngine {
    static let manifestName = ".rdm-manifest.json"
    static var keySet: ArchiveHeader.FieldKeySet { ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM,XAT")! }

    struct CreateResult {
        var payloadBytes: UInt64
        var fileCount: Int
    }

    // MARK: - 创建

    static func create(
        sourceRoot: String,
        selection: PathSelection?,
        destination: String,
        password: String,
        diskName: String,
        progress: (@Sendable (BackupProgress) -> Void)?
    ) throws -> CreateResult {
        progress?(BackupProgress(phase: .scanning, filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0, message: "扫描文件"))
        let items = try FileSync.scan(root: sourceRoot, selection: selection)
        let entries = items.compactMap { item -> ArchiveEntry? in
            switch item.kind {
            case .file: return ArchiveEntry(path: item.path, size: item.size, isDirectory: false)
            case .directory: return ArchiveEntry(path: item.path, size: 0, isDirectory: true)
            case .symlink: return ArchiveEntry(path: item.path, size: 0, isDirectory: false)
            case .other: return nil
            }
        }
        var sizes: [String: UInt64] = [:]
        for e in entries where !e.isDirectory { sizes[e.path] = e.size }
        let totalBytes = entries.reduce(UInt64(0)) { $0 + $1.size }
        let totalFiles = entries.filter { !$0.isDirectory }.count

        let params = KeyParameters.random()
        let key = try params.deriveKey(password: password)
        let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__symmetric__none, compressionAlgorithm: .lzfse)
        context.authData = try params.encoded()
        try context.setSymmetricKey(key)

        guard let fileStream = ArchiveByteStream.fileStream(path: FilePath(destination), mode: .writeOnly,
                                                            options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o600)) else {
            throw BackupError.failed("无法创建备份文件：\(destination)")
        }
        defer { try? fileStream.close() }
        guard let encryptionStream = ArchiveByteStream.encryptionStream(writingTo: fileStream, encryptionContext: context) else {
            throw BackupError.failed("无法初始化加密流")
        }
        defer { try? encryptionStream.close() }
        // 写入进度：encodeWriting 只发给编码流自己的过滤器（实测，writeDirectoryContents 的过滤器收不到），
        // 每写出一块（约 256KB）数据来一次。
        let tracker = WriteTracker(sizes: sizes, totalBytes: totalBytes, totalFiles: totalFiles, progress: progress)
        guard let encoder = ArchiveStream.encodeStream(writingTo: encryptionStream, selectUsing: { message, path, _ in
            if message == .encodeWriting { tracker.chunkWritten(path.string) }
            return .ok
        }) else {
            throw BackupError.failed("无法初始化归档编码器")
        }

        // 第一个条目：清单（在加密流内）。
        let manifest = BackupManifest(diskName: diskName, createdAt: Date(), entries: entries)
        let manifestData = try JSONEncoder().encode(manifest)
        let header = ArchiveHeader()
        header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: manifestName))
        header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
        header.append(.uint(key: ArchiveHeader.FieldKey("MOD"), value: 0o600))
        header.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(manifestData.count)))
        try encoder.writeHeader(header)
        try manifestData.withUnsafeBytes { try encoder.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: $0) }

        try encoder.writeDirectoryContents(
            archiveFrom: FilePath(sourceRoot),
            path: nil,
            keySet: keySet,
            selectUsing: { message, path, _ in
                let p = path.string
                switch message {
                case .searchPruneDirectory:
                    if VolumeSpecialItems.isSpecial(relativePath: p) { return .skip }
                    if let selection, !selection.shouldVisit(p) { return .skip }
                    return .ok
                case .searchExclude:
                    if p.isEmpty { return .ok }
                    if VolumeSpecialItems.isSpecial(relativePath: p) { return .skip }
                    if let selection, !selection.shouldVisit(p) { return .skip }
                    return .ok
                default:
                    return .ok
                }
            },
            flags: [],
            threadCount: 0
        )
        try encoder.close()
        try encryptionStream.close()
        try fileStream.close()
        return CreateResult(payloadBytes: totalBytes, fileCount: totalFiles)
    }

    // MARK: - 打开

    /// 解密并返回解码流；调用方负责按顺序关闭 `streams`。
    struct OpenedArchive {
        let decoder: ArchiveStream
        let closers: [() throws -> Void]
        /// 本工具写的归档（authData 里有我们的密钥参数）。
        let isOurs: Bool

        func close() {
            for c in closers.reversed() { try? c() }
        }
    }

    /// 打开并解密。本工具的归档解密后直接是归档流；系统 `aa archive` 生成的 .aar 默认还压缩过（文件头 “pbze”），
    /// 用 `aea encrypt` 加密后，解密出来还要再解压一层（实测）。外部归档先试读一个条目头来判断。
    static func open(path: String, password: String) throws -> OpenedArchive {
        let first = try openRaw(path: path, password: password, decompress: false)
        if first.isOurs { return first }
        // 读到条目头或读到结尾（空归档）都说明不需要解压；只有读条目头抛错才说明还有一层压缩。
        let readable: Bool
        do {
            _ = try first.decoder.readHeader()
            readable = true
        } catch {
            readable = false
        }
        first.close()
        return try openRaw(path: path, password: password, decompress: !readable)
    }

    private static func openRaw(path: String, password: String, decompress: Bool) throws -> OpenedArchive {
        guard FileManager.default.fileExists(atPath: path) else { throw BackupError.archiveMissing(path) }
        guard let fileStream = ArchiveByteStream.fileStream(path: FilePath(path), mode: .readOnly, options: [],
                                                            permissions: FilePermissions(rawValue: 0o600)) else {
            throw BackupError.archiveMissing(path)
        }
        guard let context = ArchiveEncryptionContext(from: fileStream) else {
            try? fileStream.close()
            throw BackupError.corrupted("无法读取加密头")
        }
        let params = KeyParameters.decode(context.authData)
        do {
            if let params {
                try context.setSymmetricKey(try params.deriveKey(password: password))
            } else if context.encryptionMode == .scrypt {
                // 兼容系统 aea 命令用口令加密的归档。
                try context.setPassword(password)
            } else {
                throw BackupError.notOurArchive
            }
        } catch let error as BackupError {
            try? fileStream.close()
            throw error
        } catch {
            try? fileStream.close()
            throw BackupError.wrongPassword
        }
        guard let decryption = ArchiveByteStream.decryptionStream(readingFrom: fileStream, encryptionContext: context) else {
            try? fileStream.close()
            throw BackupError.wrongPassword
        }
        var closers: [() throws -> Void] = [fileStream.close, decryption.close]
        var source = decryption
        if decompress {
            guard let decompression = ArchiveByteStream.decompressionStream(readingFrom: decryption) else {
                closers.reversed().forEach { try? $0() }
                throw BackupError.corrupted("无法解压归档")
            }
            closers.append(decompression.close)
            source = decompression
        }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: source) else {
            closers.reversed().forEach { try? $0() }
            throw BackupError.corrupted("无法解码归档")
        }
        closers.append(decoder.close)
        return OpenedArchive(decoder: decoder, closers: closers, isOurs: params != nil)
    }

    // MARK: - 列目录

    static func listContents(path: String, password: String) throws -> [ArchiveEntry] {
        let archive = try open(path: path, password: password)
        if archive.isOurs, let manifest = try? readManifest(archive.decoder) {
            archive.close()
            return manifest.entries
        }
        archive.close()
        // 没有清单（外部归档）：完整解码一遍，从每个条目头读出类型和大小，数据跳过、不落盘。
        let again = try open(path: path, password: password)
        defer { again.close() }
        let collector = ArchiveEntryCollector()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rdm-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let sink = ArchiveStream.extractStream(extractingTo: FilePath(tmp.path), selectUsing: { message, path, data in
            if message == .extractBegin {
                var size: UInt64 = 0
                var isDirectory = false
                if case .header(let header)? = data {
                    if case .blob(_, let s, _)? = header.field(forKey: ArchiveHeader.FieldKey("DAT")) { size = s }
                    if case .uint(_, let t)? = header.field(forKey: ArchiveHeader.FieldKey("TYP")) {
                        isDirectory = t == UInt64(ArchiveHeader.EntryType.directory.rawValue)
                    }
                }
                collector.add(ArchiveEntry(path: path.string, size: size, isDirectory: isDirectory))
                return .skip
            }
            return .ok
        }) else { throw BackupError.failed("无法创建解码目标") }
        do {
            _ = try ArchiveStream.process(readingFrom: again.decoder, writingTo: sink)
            try sink.close()
        } catch {
            try? sink.close()
            throw BackupError.corrupted(error.localizedDescription)
        }
        return collector.entries.filter { !$0.path.isEmpty && $0.path != manifestName }
    }

    private static func readManifest(_ decoder: ArchiveStream) throws -> BackupManifest? {
        guard let header = try decoder.readHeader(),
              case .string(_, let pat)? = header.field(forKey: ArchiveHeader.FieldKey("PAT")), pat == manifestName,
              case .blob(_, let size, _)? = header.field(forKey: ArchiveHeader.FieldKey("DAT")) else { return nil }
        var data = Data(count: Int(size))
        try data.withUnsafeMutableBytes { try decoder.readBlob(key: ArchiveHeader.FieldKey("DAT"), into: $0) }
        return try JSONDecoder().decode(BackupManifest.self, from: data)
    }

    // MARK: - 还原

    static func restore(
        path: String,
        password: String,
        to targetRoot: String,
        selection: PathSelection?,
        totals: (files: Int, bytes: UInt64, sizes: [String: UInt64]),
        progress: (@Sendable (BackupProgress) -> Void)?
    ) throws -> RestoreReport {
        let archive = try open(path: path, password: password)
        defer { archive.close() }
        let counter = ProgressCounter()
        let failures = EntryCollector()
        guard let extractor = ArchiveStream.extractStream(
            extractingTo: FilePath(targetRoot),
            selectUsing: { message, path, _ in
                let p = path.string
                switch message {
                case .extractBegin:
                    if p == manifestName { return .skip }
                    if let selection, !p.isEmpty, !selection.shouldVisit(p) { return .skip }
                    if let size = totals.sizes[p] {
                        let (files, bytes) = counter.add(bytes: size)
                        progress?(BackupProgress(phase: .restoring, filesDone: files, filesTotal: totals.files,
                                                 bytesDone: bytes, bytesTotal: totals.bytes, message: p))
                    }
                    return .ok
                case .extractFail:
                    failures.add(p)
                    return .ok
                default:
                    return .ok
                }
            },
            flags: [.ignoreOperationNotPermitted],
            threadCount: 0
        ) else { throw BackupError.failed("无法创建还原目标：\(targetRoot)") }
        do {
            _ = try ArchiveStream.process(readingFrom: archive.decoder, writingTo: extractor)
            try extractor.close()
        } catch {
            try? extractor.close()
            // AppleArchive 写盘失败时只给出 “ArchiveError error 0”，用目标卷剩余空间区分“写满”与“归档损坏”。
            let free = MountTable.entry(at: targetRoot)?.availableBytes ?? .max
            if free < RestoreSizing.safetyMargin {
                throw BackupError.insufficientSpace(needed: totals.bytes, available: free)
            }
            throw BackupError.corrupted(error.localizedDescription)
        }
        var report = RestoreReport()
        report.restoredFiles = counter.files
        report.restoredBytes = counter.bytes
        report.errors = failures.paths.map { "\($0)：还原失败" }
        return report
    }

    /// 完整解密、解压一遍但不写盘，用于校验备份完整性。
    static func verify(path: String, password: String) throws -> Int {
        let archive = try open(path: path, password: password)
        defer { archive.close() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rdm-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let collector = EntryCollector()
        guard let sink = ArchiveStream.extractStream(extractingTo: FilePath(tmp.path), selectUsing: { message, path, _ in
            if message == .extractBegin {
                collector.add(path.string)
                return .skip
            }
            return .ok
        }) else { throw BackupError.failed("无法创建校验目标") }
        do {
            _ = try ArchiveStream.process(readingFrom: archive.decoder, writingTo: sink)
            try sink.close()
        } catch {
            throw BackupError.corrupted(error.localizedDescription)
        }
        return collector.paths.filter { !$0.isEmpty && $0 != manifestName }.count
    }
}

final class ArchiveEntryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ArchiveEntry] = []

    func add(_ e: ArchiveEntry) {
        lock.lock(); storage.append(e); lock.unlock()
    }

    var entries: [ArchiveEntry] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class EntryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func add(_ p: String) {
        lock.lock(); storage.append(p); lock.unlock()
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
