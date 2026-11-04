import Foundation
import Testing
@testable import RamDiskKit

/// 真实 ram:// 盘的端到端测试，不需要管理员权限。设置 RDM_INTEGRATION=1 才运行。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RDM_INTEGRATION"] == "1"))
struct IntegrationTests {
    let manager = RamDiskManager(privileged: OsascriptExecutor())

    /// 无论成功失败都推出测试盘。
    func withCleanup(_ names: [String], _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await ejectAll(names)
            throw error
        }
        await ejectAll(names)
    }

    func ejectAll(_ names: [String]) async {
        for disk in (try? await manager.list()) ?? [] where names.contains(where: { disk.mountPoint.hasSuffix($0) }) {
            try? await manager.eject(disk, force: true)
        }
    }

    func populate(_ root: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/proj/src", withIntermediateDirectories: true)
        var big = Data(count: 80 * 1024 * 1024)
        big.withUnsafeMutableBytes { raw in for i in stride(from: 0, to: raw.count, by: 4096) { raw[i] = UInt8(truncatingIfNeeded: i / 4096) } }
        try big.write(to: URL(fileURLWithPath: root + "/proj/big.bin"))
        for i in 0..<200 { try Data("file \(i)".utf8).write(to: URL(fileURLWithPath: root + "/proj/src/f\(i).txt")) }
        try fm.createSymbolicLink(atPath: root + "/latest", withDestinationPath: "proj/big.bin")
    }

    @Test func apfsLifecycle() async throws {
        let name = "RDMTestInt"
        try await withCleanup([name, name + "Rebuilt"]) {
            let disk = try await manager.create(DiskSpec(name: name, backend: .apfs, sizeBytes: 256 * ByteSize.mib))
            #expect(disk.mountPoint == "/Volumes/\(name)")
            #expect(disk.backend == .apfs)
            #expect(disk.deviceBytes == 256 * ByteSize.mib)
            try populate(disk.mountPoint)
            let before = fingerprint(disk.mountPoint)

            // 有进程开着文件时扩容：应该询问，确认后完成，数据一致。
            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
            holder.arguments = ["30"]
            let handle1 = try #require(FileHandle(forReadingAtPath: disk.mountPoint + "/proj/src/f1.txt"))
            holder.standardInput = handle1
            try holder.run()
            try handle1.close()
            defer { holder.terminate() }
            try await Task.sleep(for: .milliseconds(300))

            let asked = Flag()
            let resized = try await ResizeService(manager: manager).resize(disk, to: 512 * ByteSize.mib, options: ResizeOptions(confirmHolders: { holders in
                asked.set(holders.contains { $0.command == "sleep" })
                return true
            }))
            #expect(asked.value, "应检测到 sleep 进程占用")
            #expect(resized.disk.mountPoint == disk.mountPoint)
            #expect(resized.disk.deviceBytes == 512 * ByteSize.mib)
            #expect(resized.disk.capacityBytes > 400 * ByteSize.mib)
            #expect(fingerprint(disk.mountPoint) == before)
            let rams = try await DiskImageInfo.attached().filter(\.isRAM)
            #expect(!rams.contains { $0.wholeDevice == disk.wholeDevice }, "旧设备应已释放")

            // 缩容到 160MB
            let shrunk = try await ResizeService(manager: manager).resize(resized.disk, to: 160 * ByteSize.mib,
                                                                          options: ResizeOptions(confirmHolders: { _ in true }))
            #expect(shrunk.disk.deviceBytes == 160 * ByteSize.mib)
            #expect(fingerprint(disk.mountPoint) == before)

            // 缩到比已用还小：拒绝
            await #expect(throws: RamDiskError.self) {
                _ = try await ResizeService(manager: manager).resize(shrunk.disk, to: 64 * ByteSize.mib)
            }

            // 拒绝切换：回滚，原盘不受影响，新设备被释放。
            // 旧 holder 的句柄指向已被替换的旧卷，需要在当前盘上重新占用一个文件。
            holder.terminate()
            let holder2 = Process()
            holder2.executableURL = URL(fileURLWithPath: "/bin/sleep")
            holder2.arguments = ["30"]
            let handle2 = try #require(FileHandle(forReadingAtPath: disk.mountPoint + "/proj/src/f2.txt"))
            holder2.standardInput = handle2
            try holder2.run()
            try handle2.close()
            defer { holder2.terminate() }
            try await Task.sleep(for: .milliseconds(300))
            let ramsBefore = try await DiskImageInfo.attached().filter(\.isRAM).count
            await #expect(throws: RamDiskError.self) {
                _ = try await ResizeService(manager: manager).resize(shrunk.disk, to: 300 * ByteSize.mib,
                                                                     options: ResizeOptions(confirmHolders: { _ in false }))
            }
            let ramsAfter = try await DiskImageInfo.attached().filter(\.isRAM).count
            #expect(ramsAfter == ramsBefore)
            let current = try #require(try await manager.disk(at: disk.mountPoint))
            #expect(current.deviceBytes == 160 * ByteSize.mib)
            #expect(fingerprint(disk.mountPoint) == before)
            holder2.terminate()

            // 备份 → 推出 → 重建 → 还原
            let support = TempDir("int-support")
            let backups = BackupService(catalog: BackupCatalog(directory: support.url))
            let pw = "integration-pass"
            let full = try await backups.create(BackupRequest(disk: current, profileID: nil, scope: .full, format: .aea,
                                                              password: pw, destinationDirectory: support.url))
            let partial = try await backups.create(BackupRequest(disk: current, profileID: nil, scope: .partial(["proj/src"]), format: .dmg,
                                                                 password: pw, destinationDirectory: support.url))
            #expect(full.fileCount == 202)
            #expect(partial.fileCount == 200)
            try await manager.eject(current)
            #expect(try await manager.disk(at: disk.mountPoint) == nil)

            let rebuilt = try await manager.create(DiskSpec(name: name + "Rebuilt", backend: .apfs, sizeBytes: 200 * ByteSize.mib))
            _ = try await backups.restore(full, password: pw, to: rebuilt.mountPoint)
            #expect(fingerprint(rebuilt.mountPoint) == before)
            try FileManager.default.removeItem(atPath: rebuilt.mountPoint + "/proj/src")
            _ = try await backups.restore(partial, password: pw, to: rebuilt.mountPoint)
            #expect(fingerprint(rebuilt.mountPoint) == before)
        }
    }

    @Test func hfsCustomMountPointWithOptions() async throws {
        let mp = "/private/tmp/RDMTestHFS-\(UUID().uuidString.prefix(6))"
        try await withCleanup([(mp as NSString).lastPathComponent]) {
            let disk = try await manager.create(DiskSpec(name: "RDMTestHFS", backend: .hfsPlus, sizeBytes: 64 * ByteSize.mib,
                                                         mountPoint: mp, options: MountOptions(hidden: true, noExec: true)))
            #expect(disk.mountPoint == mp)
            #expect(disk.backend == .hfsPlus)
            #expect(disk.hidden && disk.noExec)
            try Data("hello".utf8).write(to: URL(fileURLWithPath: mp + "/a.txt"))
            // /private/tmp 可能被虚拟机共享而出现占用进程，这里确认继续。
            let resized = try await ResizeService(manager: manager).resize(disk, to: 128 * ByteSize.mib,
                                                                           options: ResizeOptions(confirmHolders: { _ in true }))
            #expect(resized.disk.hidden && resized.disk.noExec, "扩容后应保留挂载选项")
            #expect(resized.disk.mountPoint == mp)
            #expect(try String(contentsOfFile: mp + "/a.txt", encoding: .utf8) == "hello")
        }
        try? FileManager.default.removeItem(atPath: mp)
    }

    @Test func apfsCaseSensitive() async throws {
        try await withCleanup(["RDMTestCS"]) {
            let disk = try await manager.create(DiskSpec(name: "RDMTestCS", backend: .apfsCaseSensitive, sizeBytes: 64 * ByteSize.mib))
            #expect(disk.backend == .apfsCaseSensitive)
            try Data("A".utf8).write(to: URL(fileURLWithPath: disk.mountPoint + "/A"))
            try Data("a".utf8).write(to: URL(fileURLWithPath: disk.mountPoint + "/a"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: disk.mountPoint).filter { $0.lowercased() == "a" }.count == 2)
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set(_ newValue: Bool) { lock.lock(); v = v || newValue; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
