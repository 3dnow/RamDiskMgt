import Foundation
import Security
import Testing
@testable import RamDiskKit

/// 备份进度：两种格式写入过程中都要持续报告，且最终接近总量（排查“备份没有进度”）。
@Suite(.serialized) struct BackupProgressTests {
    final class Log: @unchecked Sendable {
        let lock = NSLock()
        var events: [BackupProgress] = []
        func add(_ p: BackupProgress) { lock.lock(); events.append(p); lock.unlock() }
        var writing: [BackupProgress] { lock.lock(); defer { lock.unlock() }; return events.filter { $0.phase == .writing } }
    }

    func randomSource() throws -> TempDir {
        let source = TempDir("progress")
        for i in 0..<6 {
            var data = Data(count: 20_000_000)
            _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            try data.write(to: URL(fileURLWithPath: source.path + "/f\(i).bin"))
        }
        return source
    }

    @Test(arguments: BackupFormat.allCases)
    func writingProgressIsReported(format: BackupFormat) async throws {
        WriteTracker.minReportInterval = 0
        defer { WriteTracker.minReportInterval = 0.1 }
        let source = try randomSource()
        let support = TempDir("progress-support")
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let fake = RamDisk(name: "Progress", backend: .apfs, mountPoint: source.path, wholeDevice: nil, volumeDevice: nil,
                           deviceBytes: 0, capacityBytes: 0, usedBytes: 0, availableBytes: 0, hidden: false, noExec: false)
        let log = Log()
        _ = try await svc.create(BackupRequest(disk: fake, profileID: nil, scope: .full, format: format,
                                               password: "progress-pass", destinationDirectory: support.url)) { log.add($0) }
        let writing = log.writing
        let distinct = Set(writing.map { Int($0.fraction * 100) })
        #expect(distinct.count >= 5, "写入阶段应持续报告进度，实际不同进度值 \(distinct.count) 个")
        #expect((writing.map(\.fraction).max() ?? 0) >= 0.9, "写入进度最终应接近 100%")
        #expect(zip(writing, writing.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone }, "进度不应倒退")
    }
}

/// 钥匙图标：记住密码的备份要能按备份找回自己的密码；删除备份时清掉对应条目。
@Suite(.serialized) struct BackupKeychainTests {
    @Test func rememberedPasswordIsStoredPerBackup() async throws {
        setenv("RDM_KEYCHAIN_SERVICE", "RamDiskMgt-UnitTest", 1)
        defer { unsetenv("RDM_KEYCHAIN_SERVICE") }
        let source = TempDir("kc-src")
        source.writeText("a.txt", "hello")
        let support = TempDir("kc-support")
        let svc = BackupService(catalog: BackupCatalog(directory: support.url))
        let fake = RamDisk(name: "KC", backend: .apfs, mountPoint: source.path, wholeDevice: nil, volumeDevice: nil,
                           deviceBytes: 0, capacityBytes: 0, usedBytes: 0, availableBytes: 0, hidden: false, noExec: false)

        let remembered = try await svc.create(BackupRequest(disk: fake, profileID: nil, scope: .full, format: .aea, password: "first-pass-1",
                                                            destinationDirectory: support.url, rememberPassword: true))
        let notRemembered = try await svc.create(BackupRequest(disk: fake, profileID: nil, scope: .full, format: .aea, password: "second-pass-2",
                                                               destinationDirectory: support.url))
        #expect(remembered.passwordInKeychain && KeychainStore.load(account: remembered.keychainAccount) == "first-pass-1")
        #expect(!notRemembered.passwordInKeychain && KeychainStore.load(account: notRemembered.keychainAccount) == nil)
        #expect(remembered.warning == nil)

        try await svc.delete(remembered, moveToTrash: false)
        #expect(KeychainStore.load(account: remembered.keychainAccount) == nil, "删除备份时应清掉它的钥匙串条目")
        try await svc.delete(notRemembered, moveToTrash: false)
    }
}
