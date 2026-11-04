// 2026-10-15 排查“还原失败后推不出来”时的探索性探针（结论见 docs/测试报告.md）。设置 RDM_PROBES=1 才运行。
import Foundation
import Testing
@testable import RamDiskKit

/// 对照：写满后等待一段时间再推出，Finder 可见 vs 隐藏（Spotlight 不索引 nobrowse 卷）。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RDM_PROBES"] == "1"))
struct FullDiskEjectProbe {
    let manager = RamDiskManager(privileged: OsascriptExecutor())

    @Test(arguments: [false, true])
    func ejectAfterFillAndWait(hidden: Bool) async throws {
        let name = hidden ? "RDMTestFullHidden" : "RDMTestFullVisible"
        let disk = try await manager.create(DiskSpec(name: name, backend: .apfs, sizeBytes: 128 * ByteSize.mib,
                                                     options: MountOptions(hidden: hidden)))
        // 写入大量小文件 + 一个大文件直到写满，模拟还原失败后的状态。
        try FileManager.default.createDirectory(atPath: disk.mountPoint + "/data", withIntermediateDirectories: true)
        for i in 0..<400 { try? Data("small \(i)".utf8).write(to: URL(fileURLWithPath: disk.mountPoint + "/data/s\(i).txt")) }
        let chunk = Data(repeating: 0x5a, count: 4 * 1024 * 1024)
        if let h = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: disk.mountPoint + "/fill.bin", contents: nil); return disk.mountPoint + "/fill.bin" }()) {
            while (try? h.write(contentsOf: chunk)) != nil, (disk.refreshed().availableBytes > 0) {}
            try? h.close()
        }
        print("PROBE2[\(name)] 写满后可用：\(ByteSize.format(disk.refreshed().availableBytes))")
        for t in [3, 8, 15] {
            try await Task.sleep(for: .seconds(t == 3 ? 3 : 5))
            let hs = await ProcessHolders.holders(of: disk.mountPoint, includeSystem: true)
            print("PROBE2[\(name)] \(t)s 占用：\(hs.map { "\($0.command)(\($0.pid)) \($0.files.prefix(2))" })")
        }
        let r = try await Shell.run("/usr/sbin/diskutil", ["eject", disk.wholeDevice ?? ""])
        print("PROBE2[\(name)] 普通推出：rc=\(r.status) \(r.diagnostic.prefix(300))")
        if try await manager.disk(at: disk.mountPoint) != nil {
            try? await manager.eject(disk, force: true)
            print("PROBE2[\(name)] 已强制推出清理")
        }
    }
}

/// 对照：卷被写到连新建文件都失败时，普通卸载是否返回 ENOSPC；腾出空间后是否恢复。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RDM_PROBES"] == "1"))
struct CompletelyFullUnmountProbe {
    let manager = RamDiskManager(privileged: OsascriptExecutor())

    @Test func unmountWhenCompletelyFull() async throws {
        let disk = try await manager.create(DiskSpec(name: "RDMTestBrim", backend: .apfs, sizeBytes: 64 * ByteSize.mib))
        let mp = disk.mountPoint
        FileManager.default.createFile(atPath: mp + "/big.bin", contents: nil)
        let h = try #require(FileHandle(forWritingAtPath: mp + "/big.bin"))
        let chunk = Data(repeating: 0x5a, count: 256 * 1024)
        while (try? h.write(contentsOf: chunk)) != nil {}
        try? h.close()
        var created = 0
        while FileManager.default.createFile(atPath: mp + "/s\(created).txt", contents: Data("x".utf8)) { created += 1; if created > 100_000 { break } }
        print("PROBE3 写满：大文件 + \(created) 个小文件，可用 \(ByteSize.format(disk.refreshed().availableBytes))")
        let vol = try #require(disk.volumeDevice)
        let r1 = try await Shell.run("/usr/sbin/diskutil", ["unmount", vol])
        print("PROBE3 写满时普通卸载：rc=\(r1.status) \(r1.diagnostic.prefix(200))")
        if r1.succeeded {
            try await Shell.checked("/usr/sbin/diskutil", ["mount", vol])
        }
        try? FileManager.default.removeItem(atPath: mp + "/big.bin")
        try await Task.sleep(for: .seconds(1))
        print("PROBE3 删除大文件后可用：\(ByteSize.format(MountTable.entry(at: mp)?.availableBytes ?? 0))")
        let r2 = try await Shell.run("/usr/sbin/diskutil", ["unmount", vol])
        print("PROBE3 腾出空间后普通卸载：rc=\(r2.status) \(r2.diagnostic.prefix(200))")
        _ = try? await Shell.run("/usr/sbin/diskutil", ["eject", disk.wholeDevice ?? ""])
        if try await manager.disk(at: mp) != nil { try? await manager.eject(disk, force: true) }
    }
}

/// 尽量还原现场：约 450MB 的中小文件经 FileSync（DMG 还原同一路径）写入 128MB 的盘，失败后等 9 秒再推出。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RDM_PROBES"] == "1"))
struct IncidentReplayProbe {
    let manager = RamDiskManager(privileged: OsascriptExecutor())

    @Test(arguments: [false, true])
    func replay(hidden: Bool) async throws {
        let source = TempDir("replay-src")
        for d in 0..<10 {
            for f in 0..<30 {
                source.write("packs/d\(d)/doc\(f).md", bytes: 1_000_000 + (d * 30 + f) * 7_000, seed: UInt8((d * 30 + f) % 250))
            }
        }
        setxattr(source.path + "/packs/d0/doc0.md", "com.apple.metadata:test", "v", 1, 0, 0)
        let name = hidden ? "RDMTestReplayH" : "RDMTestReplayV"
        let disk = try await manager.create(DiskSpec(name: name, backend: .apfs, sizeBytes: 128 * ByteSize.mib,
                                                     options: MountOptions(hidden: hidden)))
        let report = try? await FileSync.sync(from: source.url, to: URL(fileURLWithPath: disk.mountPoint),
                                              options: SyncOptions(mirror: false))
        print("PROBE4[\(name)] 同步：复制 \(report?.copiedFiles ?? -1) 个，错误 \(report?.errors.count ?? -1) 条；可用 \(ByteSize.format(disk.refreshed().availableBytes))")
        try await Task.sleep(for: .seconds(9))
        print("PROBE4[\(name)] 9 秒后可用 \(ByteSize.format(disk.refreshed().availableBytes))")
        for attempt in 1...2 {
            let r = try await Shell.run("/usr/sbin/diskutil", ["unmount", disk.volumeDevice ?? ""])
            print("PROBE4[\(name)] 普通卸载 #\(attempt)：rc=\(r.status) \(r.diagnostic.prefix(200))")
            if r.succeeded { break }
            try await Task.sleep(for: .seconds(3))
        }
        _ = try? await Shell.run("/usr/sbin/diskutil", ["eject", disk.wholeDevice ?? ""])
        if try await manager.disk(at: disk.mountPoint) != nil {
            try? await manager.eject(disk, force: true)
            print("PROBE4[\(name)] 已强制推出清理")
        }
    }
}

/// 对照：AEA 合并还原覆盖同名大文件时，是否需要新旧两份空间（决定合并模式能否把被覆盖文件算作可用空间）。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RDM_PROBES"] == "1"))
struct OverwriteSpaceProbe {
    let manager = RamDiskManager(privileged: OsascriptExecutor())

    @Test(arguments: BackupFormat.allCases)
    func overwriteBigFileOnTightDisk(format: BackupFormat) async throws {
        let source = TempDir("ow-src")
        source.write("big.bin", bytes: 70_000_000, seed: 3)
        let support = TempDir("ow-support")
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let fake = RamDisk(name: "OW", backend: .apfs, mountPoint: source.path, wholeDevice: nil, volumeDevice: nil,
                           deviceBytes: 0, capacityBytes: 0, usedBytes: 0, availableBytes: 0, hidden: false, noExec: false)
        let record = try await svc.create(BackupRequest(disk: fake, profileID: nil, scope: .full, format: format,
                                                        password: "overwrite-pass", destinationDirectory: support.url))
        let disk = try await manager.create(DiskSpec(name: "RDMTestOverwrite", backend: .apfs, sizeBytes: 128 * ByteSize.mib))
        var old = Data(count: 70_000_000)
        old.withUnsafeMutableBytes { raw in for i in stride(from: 0, to: raw.count, by: 4096) { raw[i] = 0x77 } }
        try old.write(to: URL(fileURLWithPath: disk.mountPoint + "/big.bin"))
        print("PROBE5[\(format)] 写入旧文件后可用：\(ByteSize.format(disk.refreshed().availableBytes))")
        do {
            switch format {
            case .aea:
                _ = try AEAEngine.restore(path: record.archivePath, password: "overwrite-pass", to: disk.mountPoint, selection: nil,
                                          totals: (files: 1, bytes: 70_000_000, sizes: [:]), progress: nil)
            case .dmg:
                _ = try await DMGEngine.restore(path: record.archivePath, password: "overwrite-pass", to: disk.mountPoint, selection: nil, progress: nil)
            }
            let same = fingerprint(disk.mountPoint) == fingerprint(source.path)
            print("PROBE5[\(format)] 覆盖还原成功，内容与备份一致：\(same)")
        } catch {
            print("PROBE5[\(format)] 覆盖还原失败：\(error.localizedDescription)")
        }
        try? await manager.eject(disk, force: true)
    }
}

/// 对照：AEA 损坏位置离清单多远时，只读清单的 contents() 还能通过（决定 F7 的风险是否真实存在）。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RDM_PROBES"] == "1"))
struct CorruptionReachProbe {
    @Test func manifestReadabilityVsCorruptionOffset() async throws {
        let source = TempDir("reach-src")
        for i in 0..<6 { source.write("f\(i).bin", bytes: 50_000_000, seed: UInt8(i + 30)) }
        let support = TempDir("reach-support")
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let fake = RamDisk(name: "Reach", backend: .apfs, mountPoint: source.path, wholeDevice: nil, volumeDevice: nil,
                           deviceBytes: 0, capacityBytes: 0, usedBytes: 0, availableBytes: 0, hidden: false, noExec: false)
        let record = try await svc.create(BackupRequest(disk: fake, profileID: nil, scope: .full, format: .aea,
                                                        password: "reach-password", destinationDirectory: support.url))
        let original = try Data(contentsOf: record.archiveURL)
        print("PROBE6 归档大小 \(ByteSize.format(UInt64(original.count)))")
        for fraction in [0.05, 0.3, 0.6, 0.9] {
            var damaged = original
            let offset = Int(Double(original.count) * fraction)
            damaged.replaceSubrange(offset..<(offset + 4096), with: Data(repeating: 0xA5, count: 4096))
            try damaged.write(to: record.archiveURL)
            let listOK: String
            do { _ = try await svc.contents(of: record, password: "reach-password"); listOK = "能读出清单" } catch { listOK = "读清单失败" }
            let verifyOK: String
            do { _ = try await svc.verify(record, password: "reach-password"); verifyOK = "完整校验通过" } catch { verifyOK = "完整校验失败" }
            print("PROBE6 损坏位置 \(Int(fraction * 100))%：\(listOK)，\(verifyOK)")
        }
        try original.write(to: record.archiveURL)
    }
}

/// 探针：备份时进度回调实际到达的次数与阶段（排查“备份没有进度”）。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RDM_PROBES"] == "1"))
struct BackupProgressProbe {
    final class Log: @unchecked Sendable {
        let lock = NSLock()
        var events: [(Double, String, Double)] = []
        let start = Date()
        func add(_ p: BackupProgress) {
            lock.lock(); events.append((Date().timeIntervalSince(start), p.phaseName, p.fraction)); lock.unlock()
        }
    }

    @Test(arguments: BackupFormat.allCases)
    func progressEvents(format: BackupFormat) async throws {
        let source = TempDir("progress-src")
        // 不可压缩的随机数据，接近真实的照片 / 视频 / 压缩包。
        for i in 0..<12 {
            var data = Data(count: 25_000_000)
            _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            try FileManager.default.createDirectory(atPath: source.path + "/d\(i % 3)", withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: source.path + "/d\(i % 3)/f\(i).bin"))
        }
        let support = TempDir("progress-support")
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let fake = RamDisk(name: "Progress", backend: .apfs, mountPoint: source.path, wholeDevice: nil, volumeDevice: nil,
                           deviceBytes: 0, capacityBytes: 0, usedBytes: 0, availableBytes: 0, hidden: false, noExec: false)
        let log = Log()
        _ = try await svc.create(BackupRequest(disk: fake, profileID: nil, scope: .full, format: format,
                                               password: "progress-pass", destinationDirectory: support.url)) { log.add($0) }
        let byPhase = Dictionary(grouping: log.events, by: { $0.1 }).mapValues(\.count)
        let fractions = log.events.map(\.2)
        print("PROBE7[\(format)] 回调 \(log.events.count) 次，按阶段：\(byPhase)，进度取值：\(Set(fractions.map { Int($0 * 100) }).sorted().prefix(12))…，总耗时 \(String(format: "%.1f", log.events.last?.0 ?? 0)) 秒")
    }
}
