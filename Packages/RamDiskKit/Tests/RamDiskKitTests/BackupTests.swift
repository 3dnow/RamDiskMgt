import Foundation
import Testing
@testable import RamDiskKit

@Suite(.serialized) struct BackupTests {
    let password = "test-pass-123"

    func makeVolume() -> TempDir {
        let v = TempDir("vol")
        v.write("data/large.bin", bytes: 2_000_000)
        v.write("data/small.bin", bytes: 1_000, seed: 4)
        v.writeText("docs/readme.md", "# 说明")
        v.writeText("docs/deep/note.txt", "deep")
        v.symlink("shortcut", to: "docs/readme.md")
        v.writeText(".fseventsd/x", "system item")
        return v
    }

    func fakeDisk(_ v: TempDir) -> RamDisk {
        RamDisk(name: "UnitTest", backend: .apfs, mountPoint: v.path, wholeDevice: nil, volumeDevice: nil,
                deviceBytes: 0, capacityBytes: 0, usedBytes: 0, availableBytes: 0, hidden: false, noExec: false)
    }

    func service(_ support: TempDir) -> BackupService {
        BackupService(catalog: BackupCatalog(directory: support.url))
    }

    @Test(arguments: BackupFormat.allCases)
    func fullRoundTrip(format: BackupFormat) async throws {
        let volume = makeVolume()
        let support = TempDir("support")
        let svc = service(support)
        let record = try await svc.create(BackupRequest(disk: fakeDisk(volume), profileID: nil, scope: .full, format: format,
                                                        password: password, destinationDirectory: support.url))
        #expect(record.fileCount == 5)
        #expect(record.archiveExists)
        #expect(await svc.catalog.all().count == 1)
        // 备份文件里不应出现明文
        let raw = try Data(contentsOf: record.archiveURL)
        #expect(raw.range(of: Data("readme.md".utf8)) == nil, "文件名不应以明文出现在备份中")

        let entries = try await svc.contents(of: record, password: password)
        #expect(Set(entries.filter { !$0.isDirectory }.map(\.path)) == ["data/large.bin", "data/small.bin", "docs/readme.md", "docs/deep/note.txt", "shortcut"])
        #expect(try await svc.verify(record, password: password) >= 5)

        let target = TempDir("restore")
        let report = try await svc.restore(record, password: password, to: target.path)
        #expect(report.errors.isEmpty)
        #expect(fingerprint(volume.path) == fingerprint(target.path))
        #expect(!FileManager.default.fileExists(atPath: target.path + "/" + AEAEngine.manifestName))
    }

    @Test func sameSecondBackupsGetDistinctFileNames() throws {
        let dir = TempDir("names")
        let first = BackupService.uniqueDestination(in: dir.url, fileName: "Cache-20261104-120000.aea")
        #expect(first.hasSuffix("/Cache-20261104-120000.aea"))
        try Data().write(to: URL(fileURLWithPath: first))
        let second = BackupService.uniqueDestination(in: dir.url, fileName: "Cache-20261104-120000.aea")
        #expect(second.hasSuffix("/Cache-20261104-120000-2.aea"))
        try Data().write(to: URL(fileURLWithPath: second))
        let third = BackupService.uniqueDestination(in: dir.url, fileName: "Cache-20261104-120000.aea")
        #expect(third.hasSuffix("/Cache-20261104-120000-3.aea"))
    }

    @Test func relocateMissingFindsMovedArchives() async throws {
        let volume = makeVolume()
        let support = TempDir("support")
        let svc = service(support)
        let record = try await svc.create(BackupRequest(disk: fakeDisk(volume), profileID: nil, scope: .full, format: .aea,
                                                        password: password, destinationDirectory: support.url))
        let moved = TempDir("moved")
        let target = moved.url.appendingPathComponent("sub/\(record.archiveURL.lastPathComponent)")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: record.archiveURL, to: target)
        #expect(try await svc.relocateMissing(searching: moved.url) == 1)
        let updated = try #require(await svc.catalog.record(id: record.id))
        // 枚举器会把 /var 解析成 /private/var，按解析后的路径比较。
        #expect(URL(fileURLWithPath: updated.archivePath).resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && updated.archiveExists,
                "实际 \(updated.archivePath)，期望 \(target.path)")
        #expect(try await svc.relocateMissing(searching: moved.url) == 0, "已找回的不再重复处理")
    }

    @Test(arguments: BackupFormat.allCases)
    func partialBackupAndPartialRestore(format: BackupFormat) async throws {
        let volume = makeVolume()
        let support = TempDir("support")
        let svc = service(support)
        let record = try await svc.create(BackupRequest(disk: fakeDisk(volume), profileID: nil, scope: .partial(["docs", "data/small.bin"]),
                                                        format: format, password: password, destinationDirectory: support.url))
        #expect(record.fileCount == 3)
        let files = Set(try await svc.contents(of: record, password: password).filter { !$0.isDirectory }.map(\.path))
        #expect(files == ["data/small.bin", "docs/readme.md", "docs/deep/note.txt"])

        let target = TempDir("restore")
        target.writeText("existing.txt", "keep me")
        _ = try await svc.restore(record, password: password, to: target.path, selection: ["docs/deep"])
        #expect(FileManager.default.fileExists(atPath: target.path + "/docs/deep/note.txt"))
        #expect(!FileManager.default.fileExists(atPath: target.path + "/docs/readme.md"))
        #expect(!FileManager.default.fileExists(atPath: target.path + "/data/small.bin"))
        #expect(FileManager.default.fileExists(atPath: target.path + "/existing.txt"))
        // DMG 暂存目录必须清理掉
        #expect(try FileManager.default.contentsOfDirectory(atPath: volume.path).allSatisfy { !$0.hasPrefix(".rdm-") })
    }

    @Test(arguments: BackupFormat.allCases)
    func wrongPasswordIsRejected(format: BackupFormat) async throws {
        let volume = makeVolume()
        let support = TempDir("support")
        let svc = service(support)
        let record = try await svc.create(BackupRequest(disk: fakeDisk(volume), profileID: nil, scope: .full, format: format,
                                                        password: password, destinationDirectory: support.url))
        let target = TempDir("restore")
        target.writeText("untouched.txt", "x")
        await #expect(throws: BackupError.self) {
            _ = try await svc.restore(record, password: "wrong-password!", to: target.path, mode: .replace)
        }
        #expect(FileManager.default.fileExists(atPath: target.path + "/untouched.txt"), "密码错误时不应清空目标")
    }

    @Test(arguments: BackupFormat.allCases)
    func mergeOverwritesAndReplaceClears(format: BackupFormat) async throws {
        let volume = makeVolume()
        let support = TempDir("support")
        let svc = service(support)
        let record = try await svc.create(BackupRequest(disk: fakeDisk(volume), profileID: nil, scope: .full, format: format,
                                                        password: password, destinationDirectory: support.url))
        let target = TempDir("restore")
        target.writeText("docs/readme.md", "stale content that must be overwritten")
        target.writeText("other.txt", "survives merge")
        _ = try await svc.restore(record, password: password, to: target.path, mode: .merge)
        #expect(try String(contentsOfFile: target.path + "/docs/readme.md", encoding: .utf8) == "# 说明")
        #expect(FileManager.default.fileExists(atPath: target.path + "/other.txt"))

        _ = try await svc.restore(record, password: password, to: target.path, mode: .replace)
        #expect(!FileManager.default.fileExists(atPath: target.path + "/other.txt"))
        #expect(fingerprint(volume.path) == fingerprint(target.path))
    }

    @Test func shortPasswordRejected() async throws {
        let volume = makeVolume()
        let support = TempDir("support")
        await #expect(throws: BackupError.self) {
            _ = try await service(support).create(BackupRequest(disk: fakeDisk(volume), profileID: nil, scope: .full, format: .aea,
                                                                password: "short", destinationDirectory: support.url))
        }
    }

    @Test func keyParametersRoundTrip() throws {
        let p = KeyParameters.random(iterations: 1000)
        let decoded = KeyParameters.decode(try p.encoded())
        #expect(decoded == p)
        let k1 = try p.deriveKey(password: "abcdefgh")
        let k2 = try p.deriveKey(password: "abcdefgh")
        let k3 = try p.deriveKey(password: "abcdefgi")
        #expect(k1 == k2 && k1 != k3)
    }
}

/// 别的工具（系统 aa + aea 命令）生成的加密归档：没有我们的清单，大小要从条目头读出来，否则空间预检形同虚设。
@Suite struct ForeignArchiveTests {
    @Test func foreignAEAListsRealSizes() async throws {
        let dir = TempDir("foreign")
        dir.write("src/a.bin", bytes: 3_000_000, seed: 4)
        dir.write("src/sub/b.bin", bytes: 120_000, seed: 5)
        let aar = dir.path + "/x.aar", aea = dir.path + "/x.aea"
        try await Shell.checked("/usr/bin/aa", ["archive", "-d", dir.path + "/src", "-o", aar])
        try await Shell.checked("/usr/bin/aea", ["encrypt", "-profile", "hkdf_sha256_aesctr_hmac__scrypt__none",
                                                 "-password-value", "foreign-password-0123456", "-i", aar, "-o", aea])
        let support = TempDir("foreign-support")
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let record = try await svc.importArchive(at: URL(fileURLWithPath: aea))
        let entries = try await svc.contents(of: record, password: "foreign-password-0123456")
        let files = Dictionary(uniqueKeysWithValues: entries.filter { !$0.isDirectory }.map { ($0.path, $0.size) })
        #expect(files["a.bin"] == 3_000_000)
        #expect(files["sub/b.bin"] == 120_000)
        #expect(entries.contains { $0.path == "sub" && $0.isDirectory })
        #expect(RestoreSizing.requiredBytes(entries: entries) >= 3_120_000)

        let target = TempDir("foreign-restore")
        let report = try await svc.restore(record, password: "foreign-password-0123456", to: target.path)
        #expect(report.errors.isEmpty)
        #expect(fingerprint(target.path) == fingerprint(dir.path + "/src"), "外部归档应完整还原")
        await #expect(throws: BackupError.self) {
            _ = try await svc.contents(of: record, password: "wrong-password-0123456")
        }
    }
}
