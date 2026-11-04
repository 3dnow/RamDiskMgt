import Darwin
import Foundation
import Testing
@testable import RamDiskKit

/// 2026-10-15 代码复查发现的还原安全问题（不需要 RAM 盘）。
@Suite(.serialized) struct RestoreSafetyTests {
    let password = "safety-pass-123"

    func makeBackup(format: BackupFormat) async throws -> (TempDir, TempDir, BackupService, BackupRecord) {
        let source = TempDir("safety-src")
        source.write("big.bin", bytes: 6_000_000, seed: 11)
        source.write("docs/a.txt", bytes: 2_000, seed: 12)
        let support = TempDir("safety-support")
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let fake = RamDisk(name: "Safety", backend: .apfs, mountPoint: source.path, wholeDevice: nil, volumeDevice: nil,
                           deviceBytes: 0, capacityBytes: 0, usedBytes: 0, availableBytes: 0, hidden: false, noExec: false)
        let record = try await svc.create(BackupRequest(disk: fake, profileID: nil, scope: .full, format: format,
                                                        password: password, destinationDirectory: support.url))
        return (source, support, svc, record)
    }

    /// F7：备份后半段损坏时，“替换”不能先把目标清空。
    /// 截断的归档连清单都读不出来（实测 contents() 直接报 corrupted），所以用“后段字节损坏”：
    /// 实测损坏位置在 30%/60%/90% 时清单都能读出、完整校验失败（RestoreFailureProbe.CorruptionReachProbe）。
    /// 测试数据压缩率很高、归档很小，所以只改 64 字节，避免覆盖到开头的清单。
    @Test func replaceWithCorruptedAEAKeepsTarget() async throws {
        // 要足够多的 1MB 数据段，损坏才会落在数据区而不是开头的簇头里（小归档里簇头占比很大）。
        let source = TempDir("safety-src-big")
        for i in 0..<4 { source.write("f\(i).bin", bytes: 40_000_000, seed: UInt8(i + 40)) }
        let support = TempDir("safety-support-big")
        defer { withExtendedLifetime((source, support)) {} }
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let fake = RamDisk(name: "SafetyBig", backend: .apfs, mountPoint: source.path, wholeDevice: nil, volumeDevice: nil,
                           deviceBytes: 0, capacityBytes: 0, usedBytes: 0, availableBytes: 0, hidden: false, noExec: false)
        let record = try await svc.create(BackupRequest(disk: fake, profileID: nil, scope: .full, format: .aea,
                                                        password: password, destinationDirectory: support.url))
        let handle = try FileHandle(forUpdating: record.archiveURL)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size * 9 / 10)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 64))
        try handle.close()

        let listed = try await svc.contents(of: record, password: password)
        #expect(!listed.isEmpty, "开头完好时清单仍能读出——这正是旧流程会放行的情况")

        let target = TempDir("safety-target")
        target.writeText("keep.txt", "existing content")
        await #expect(throws: (any Error).self) {
            _ = try await svc.restore(record, password: password, to: target.path, mode: .replace)
        }
        #expect(FileManager.default.fileExists(atPath: target.path + "/keep.txt"), "校验失败时目标原内容必须保留")
    }

    /// F9：目标已不是挂载点（盘被推出后只剩目录）时拒绝还原，什么都不写。
    @Test(arguments: BackupFormat.allCases)
    func refusesWhenTargetIsNotAMountPoint(format: BackupFormat) async throws {
        let (source, support, svc, record) = try await makeBackup(format: format)
        defer { withExtendedLifetime((source, support)) {} }
        let target = TempDir("not-a-mount")
        do {
            _ = try await svc.restore(record, password: password, to: target.path, requireMountPoint: true)
            Issue.record("应当拒绝")
        } catch BackupError.targetGone {
            // 预期
        }
        #expect(fingerprint(target.path).isEmpty)
    }

    /// F10：可回收空间只按实际占用、同一 inode 只算一次；合并模式下多链接文件不计。
    @Test func reclaimCountsHardLinksOnce() throws {
        let root = TempDir("reclaim")
        root.write("a.bin", bytes: 4_000_000, seed: 21)
        #expect(link(root.path + "/a.bin", root.path + "/a-link.bin") == 0)
        root.write("b.bin", bytes: 1_000_000, seed: 22)
        let replace = RestoreSizing.reclaimableBytes(targetRoot: root.path, entries: [], selection: nil, mode: .replace)
        #expect(replace >= 5_000_000 && replace < 5_400_000, "硬链接只算一次：\(replace)")

        let entries = [ArchiveEntry(path: "a.bin", size: 4_000_000, isDirectory: false),
                       ArchiveEntry(path: "b.bin", size: 1_000_000, isDirectory: false)]
        let merge = RestoreSizing.reclaimableBytes(targetRoot: root.path, entries: entries, selection: nil, mode: .merge)
        #expect(merge >= 1_000_000 && merge < 1_200_000, "多链接的 a.bin 覆盖后不会释放空间：\(merge)")
    }

    /// 外部空归档：读到结尾不是“需要解压”。
    @Test func emptyForeignArchiveListsNothing() async throws {
        let dir = TempDir("foreign-empty")
        try FileManager.default.createDirectory(atPath: dir.path + "/src", withIntermediateDirectories: true)
        try await Shell.checked("/usr/bin/aa", ["archive", "-d", dir.path + "/src", "-o", dir.path + "/x.aar"])
        try await Shell.checked("/usr/bin/aea", ["encrypt", "-profile", "hkdf_sha256_aesctr_hmac__scrypt__none",
                                                 "-password-value", "foreign-password-0123456", "-i", dir.path + "/x.aar", "-o", dir.path + "/x.aea"])
        let support = TempDir("foreign-empty-support")
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let record = try await svc.importArchive(at: URL(fileURLWithPath: dir.path + "/x.aea"))
        let entries = try await svc.contents(of: record, password: "foreign-password-0123456")
        #expect(entries.filter { !$0.isDirectory }.isEmpty)
    }
}
