import Foundation
import Testing
@testable import RamDiskKit

/// 还原空间检查与容量估算，使用真实 ram:// 盘。设置 RDM_INTEGRATION=1 才运行。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RDM_INTEGRATION"] == "1"))
struct RestoreSpaceTests {
    let manager = RamDiskManager(privileged: OsascriptExecutor())
    let password = "space-test-pass"

    func fakeDisk(_ dir: TempDir) -> RamDisk {
        RamDisk(name: "SpaceSrc", backend: .apfs, mountPoint: dir.path, wholeDevice: nil, volumeDevice: nil,
                deviceBytes: 0, capacityBytes: 0, usedBytes: 0, availableBytes: 0, hidden: false, noExec: false)
    }

    func backup(_ source: TempDir, format: BackupFormat, support: TempDir) async throws -> (BackupService, BackupRecord) {
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let record = try await svc.create(BackupRequest(disk: fakeDisk(source), profileID: nil, scope: .full, format: format,
                                                        password: password, destinationDirectory: support.url))
        return (svc, record)
    }

    func withDisk(_ name: String, size: UInt64, _ body: (RamDisk) async throws -> Void) async throws {
        let disk = try await manager.create(DiskSpec(name: name, backend: .apfs, sizeBytes: size))
        do { try await body(disk) } catch {
            try? await manager.eject(disk, force: true)
            throw error
        }
        if try await manager.disk(at: disk.mountPoint) != nil { try? await manager.eject(disk, force: true) }
    }

    @Test(arguments: BackupFormat.allCases)
    func tooSmallTargetIsRejectedBeforeWriting(format: BackupFormat) async throws {
        let source = TempDir("space-src")
        for i in 0..<4 { source.write("big\(i).bin", bytes: 50_000_000, seed: UInt8(i + 1)) }
        let support = TempDir("space-support")
        let (svc, record) = try await backup(source, format: format, support: support)
        try await withDisk("RDMTestTooSmall", size: 128 * ByteSize.mib) { disk in
            await #expect(throws: BackupError.self) {
                _ = try await svc.restore(record, password: password, to: disk.mountPoint)
            }
            do {
                _ = try await svc.restore(record, password: password, to: disk.mountPoint)
            } catch BackupError.insufficientSpace(let needed, let available) {
                #expect(needed > available)
            } catch {
                Issue.record("应当是空间不足，实际：\(error)")
            }
            #expect(fingerprint(disk.mountPoint).isEmpty, "放不下时不应写入任何文件")
            try await manager.eject(disk, force: false)
        }
    }

    /// 跳过预检直接写满：错误应识别为空间不足，而不是“备份文件损坏”。
    @Test(arguments: BackupFormat.allCases)
    func engineReportsOutOfSpaceNotCorruption(format: BackupFormat) async throws {
        let source = TempDir("space-src2")
        for i in 0..<3 { source.write("big\(i).bin", bytes: 60_000_000, seed: UInt8(i + 9)) }
        let support = TempDir("space-support2")
        let (_, record) = try await backup(source, format: format, support: support)
        try await withDisk("RDMTestEngineFull", size: 96 * ByteSize.mib) { disk in
            do {
                switch format {
                case .aea:
                    _ = try AEAEngine.restore(path: record.archivePath, password: password, to: disk.mountPoint, selection: nil,
                                              totals: (files: 3, bytes: 180_000_000, sizes: [:]), progress: nil)
                case .dmg:
                    _ = try await DMGEngine.restore(path: record.archivePath, password: password, to: disk.mountPoint,
                                                    selection: nil, progress: nil)
                }
                Issue.record("应当失败")
            } catch BackupError.insufficientSpace {
                // 预期
            } catch {
                Issue.record("应当是空间不足，实际：\(error.localizedDescription)")
            }
            try? await manager.eject(disk, force: true)
        }
    }

    /// 按推荐容量新建的盘必须放得下，并留出安全余量。
    @Test(arguments: [
        ("小文件", 3000, 1_000, 3_000),
        ("中等文件", 300, 1_000_000, 1_400_000),
        ("大文件", 4, 40_000_000, 60_000_000),
    ])
    func recommendedSizeFits(label: String, count: Int, minBytes: Int, maxBytes: Int) async throws {
        let source = TempDir("fit-src")
        for i in 0..<count {
            let size = minBytes + (maxBytes - minBytes) * i / max(1, count - 1)
            source.write("d\(i % 20)/f\(i).bin", bytes: size, seed: UInt8(i % 250))
        }
        let support = TempDir("fit-support")
        let (svc, record) = try await backup(source, format: .aea, support: support)
        let entries = try await svc.contents(of: record, password: password)
        let needed = RestoreSizing.requiredBytes(entries: entries) + RestoreSizing.safetyMargin
        let size = RestoreSizing.recommendedDiskSize(forContent: needed, backend: .apfs)
        try await withDisk("RDMTestFit", size: size) { disk in
            let report = try await svc.restore(record, password: password, to: disk.mountPoint)
            #expect(report.errors.isEmpty)
            #expect(fingerprint(disk.mountPoint) == fingerprint(source.path), "\(label)：内容应完整还原")
            let free = disk.refreshed().availableBytes
            print("FIT[\(label)] 内容 \(ByteSize.format(record.payloadBytes))，估算 \(ByteSize.format(needed))，盘 \(ByteSize.format(size))，还原后剩余 \(ByteSize.format(free))")
            #expect(free >= RestoreSizing.safetyMargin, "\(label)：还原后应保留安全余量，实际剩余 \(ByteSize.format(free))")
        }
    }
}
