import Darwin
import Foundation

/// 在同一个卷里用硬链接把选中的文件按原目录结构摆进暂存目录：不额外占内存，tmpfs 与 APFS 都支持。
enum HardlinkStager {
    static func stage(root: String, selection: PathSelection?, into staging: String,
                      progress: ((Int, Int) -> Void)? = nil) throws -> (files: Int, bytes: UInt64) {
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        var files = 0
        var bytes: UInt64 = 0
        let items = try FileSync.scan(root: root, selection: selection)
        for (index, item) in items.enumerated() {
            if index % 500 == 0 { progress?(index, items.count) }
            let src = root + "/" + item.path
            let dst = staging + "/" + item.path
            switch item.kind {
            case .directory:
                try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
                _ = copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR))
            case .file:
                try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if link(src, dst) != 0 {
                    // 硬链接失败（例如跨卷）时退回复制。
                    try FileSync.copyItem(from: src, to: dst)
                }
                files += 1
                bytes += item.size
            case .symlink:
                try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try FileSync.copyItem(from: src, to: dst)
                files += 1
            case .other:
                break
            }
        }
        return (files, bytes)
    }
}

/// 读写加密 DMG 备份（`diskutil image`）。
enum DMGEngine {
    static func create(
        sourceRoot: String,
        selection: PathSelection?,
        destination: String,
        password: String,
        volumeName: String,
        progress: (@Sendable (BackupProgress) -> Void)?
    ) async throws -> (payloadBytes: UInt64, fileCount: Int) {
        let staging = sourceRoot + "/" + VolumeSpecialItems.appPrefix + "staging-" + UUID().uuidString.prefix(8)
        defer { try? FileManager.default.removeItem(atPath: staging) }

        progress?(BackupProgress(phase: .staging, filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0, message: "建立硬链接暂存"))
        let staged: (files: Int, bytes: UInt64)
        do {
            staged = try HardlinkStager.stage(root: sourceRoot, selection: selection, into: staging) { done, total in
                progress?(BackupProgress(phase: .staging, filesDone: done, filesTotal: total, bytesDone: 0, bytesTotal: 0,
                                         message: "建立硬链接暂存 \(done)/\(total)"))
            }
        } catch {
            throw BackupError.failed("准备暂存目录失败（磁盘可能已满）：\(error.localizedDescription)")
        }
        try Task.checkCancellation()

        if FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.removeItem(atPath: destination)
        }
        let total = staged.bytes
        let progressHandler: @Sendable (String) -> Void = { text in
            // 输出形如 "[5% completed] [79% completed] ..."
            let pattern = /\[(\d+)% completed\]/
            if let last = text.matches(of: pattern).last, let percent = UInt64(last.1) {
                progress?(BackupProgress(phase: .writing, filesDone: 0, filesTotal: staged.files,
                                         bytesDone: total * percent / 100, bytesTotal: total, message: "写入加密映像 \(percent)%"))
            }
        }
        progress?(BackupProgress(phase: .writing, filesDone: 0, filesTotal: staged.files, bytesDone: 0, bytesTotal: total, message: "写入加密映像"))
        let args = ["image", "create", "--encrypt", "--stdinpass", "from", "--format", "ULFO", "--volumeName", volumeName, staging, destination]
        let first = try await Shell.run("/usr/sbin/diskutil", args, stdin: Data(password.utf8),
                                        onOutput: progressHandler, onErrorOutput: progressHandler)
        if !first.succeeded {
            // 偶发 “Disk image operation failed with error code 156”，原因未明（见 docs/测试报告.md）。
            // 用 --verbose 再试一次，同时把两次输出记入日志，留作诊断证据。
            try? FileManager.default.removeItem(atPath: destination)
            let verboseArgs = ["image", "--verbose"] + args.dropFirst()
            let second = try await Shell.run("/usr/sbin/diskutil", Array(verboseArgs), stdin: Data(password.utf8),
                                             onOutput: progressHandler, onErrorOutput: progressHandler)
            DiagnosticsLog.append("dmg-create", """
                首次失败（退出码 \(first.status)）：\(first.diagnostic)
                verbose 重试\(second.succeeded ? "成功" : "失败（退出码 \(second.status)）")：
                \(second.stdout.suffix(4000))
                \(second.stderr.suffix(4000))
                """)
            guard second.succeeded else { throw CommandError(command: "diskutil image create", result: second) }
        }
        return (staged.bytes, staged.files)
    }

    /// 只读挂载加密映像到临时目录。
    struct Mounted {
        let mountPoint: String
        let device: String
    }

    static func attach(path: String, password: String) async throws -> Mounted {
        guard FileManager.default.fileExists(atPath: path) else { throw BackupError.archiveMissing(path) }
        let mp = FileManager.default.temporaryDirectory.appendingPathComponent("rdm-dmg-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
        let result = try await Shell.run(
            "/usr/sbin/diskutil",
            ["image", "attach", "--stdinpass", "--readOnly", "--nobrowse", "--mountPoint", mp, path],
            stdin: Data(password.utf8)
        )
        guard result.succeeded else {
            try? FileManager.default.removeItem(atPath: mp)
            if result.diagnostic.localizedCaseInsensitiveContains("passphrase") { throw BackupError.wrongPassword }
            throw BackupError.failed("挂载备份映像失败：\(result.diagnostic)")
        }
        // 输出最后一行形如 "/dev/disk12s1\tApple_APFS_Volume\t<mount>"
        let device = result.stdout.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("/dev/") else { return nil }
            return line.split(whereSeparator: \.isWhitespace).first.map { String($0.dropFirst(5)) }
        }.first ?? ""
        return Mounted(mountPoint: mp, device: device)
    }

    static func detach(_ mounted: Mounted) async {
        let target = mounted.device.isEmpty ? mounted.mountPoint : wholeDisk(of: mounted.device)
        let result = try? await Shell.run("/usr/sbin/diskutil", ["eject", target])
        if result?.succeeded != true {
            _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", "-force", mounted.mountPoint])
        }
        try? FileManager.default.removeItem(atPath: mounted.mountPoint)
    }

    /// disk12s1 → disk12
    static func wholeDisk(of device: String) -> String {
        guard let range = device.range(of: #"^disk\d+"#, options: .regularExpression) else { return device }
        return String(device[range])
    }

    static func listContents(path: String, password: String) async throws -> [ArchiveEntry] {
        let mounted = try await attach(path: path, password: password)
        let items: [TreeItem]
        do {
            items = try FileSync.scan(root: mounted.mountPoint, selection: nil)
            await detach(mounted)
        } catch {
            await detach(mounted)
            throw error
        }
        return items.compactMap { item in
            switch item.kind {
            case .directory: return ArchiveEntry(path: item.path, size: 0, isDirectory: true)
            case .file, .symlink: return ArchiveEntry(path: item.path, size: item.size, isDirectory: false)
            case .other: return nil
            }
        }
    }

    /// - Parameter beforeCopy: 映像挂载成功之后、开始复制之前执行（替换模式在这里清空目标）。
    static func restore(
        path: String,
        password: String,
        to targetRoot: String,
        selection: [String]?,
        beforeCopy: (() throws -> Void)? = nil,
        progress: (@Sendable (BackupProgress) -> Void)?
    ) async throws -> RestoreReport {
        progress?(BackupProgress(phase: .reading, filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0, message: "挂载加密映像"))
        let mounted = try await attach(path: path, password: password)
        let outcome: Result<SyncReport, Error>
        do {
            try beforeCopy?()
            let report = try await FileSync.sync(
                from: URL(fileURLWithPath: mounted.mountPoint),
                to: URL(fileURLWithPath: targetRoot),
                options: SyncOptions(mirror: false, selection: selection)
            ) { p in
                progress?(BackupProgress(phase: .restoring, filesDone: p.filesDone, filesTotal: p.filesTotal,
                                         bytesDone: p.bytesDone, bytesTotal: p.bytesTotal, message: p.currentPath))
            }
            outcome = .success(report)
        } catch {
            outcome = .failure(error)
        }
        // 只推出一次：两次推出之间设备号可能被别的盘复用。
        await detach(mounted)

        let free = MountTable.entry(at: targetRoot)?.availableBytes ?? 0
        switch outcome {
        case .success(let report):
            if report.outOfSpace {
                throw BackupError.insufficientSpace(needed: report.copiedBytes + report.failedBytes, available: free)
            }
            return RestoreReport(restoredFiles: report.copiedFiles, restoredBytes: report.copiedBytes, errors: report.errors)
        case .failure(let error):
            if RestoreSizing.isOutOfSpace(error) { throw BackupError.insufficientSpace(needed: 0, available: free) }
            throw error
        }
    }

    static func verify(path: String, password: String) async throws -> Int {
        let result = try await Shell.run("/usr/sbin/diskutil", ["image", "info", "--stdinpass", path], stdin: Data(password.utf8))
        guard result.succeeded else {
            if result.diagnostic.localizedCaseInsensitiveContains("passphrase") { throw BackupError.wrongPassword }
            throw BackupError.corrupted(result.diagnostic)
        }
        // 挂载并完整读取一遍目录树，确认文件系统可读。
        let entries = try await listContents(path: path, password: password)
        return entries.filter { !$0.isDirectory }.count
    }
}
