import Foundation
import Testing
@testable import RamDiskKit

@Suite struct FileSyncTests {
    func makeSource() -> TempDir {
        let src = TempDir("src")
        src.write("big.bin", bytes: 3_000_000)
        src.write("dir/a.bin", bytes: 10_000, seed: 2)
        src.write("dir/sub/b.bin", bytes: 20_000, seed: 3)
        src.writeText("dir/sub/文本.txt", "你好")
        src.writeText("empty-dir/.keep", "")
        src.symlink("link", to: "dir/a.bin")
        src.writeText(".fseventsd/ignored", "system")
        return src
    }

    @Test func fullSyncThenIncremental() async throws {
        let src = makeSource()
        let dst = TempDir("dst")
        setxattr(src.path + "/big.bin", "com.rdm.test", "v", 1, 0, 0)

        let first = try await FileSync.sync(from: src.url, to: dst.url)
        #expect(first.errors.isEmpty)
        #expect(fingerprint(src.path) == fingerprint(dst.path))
        #expect(!FileManager.default.fileExists(atPath: dst.path + "/.fseventsd"), "系统条目不应被复制")
        var buf = [CChar](repeating: 0, count: 8)
        #expect(getxattr(dst.path + "/big.bin", "com.rdm.test", &buf, 8, 0, 0) == 1, "扩展属性应保留")

        // 改一个、删一个、加一个
        src.write("dir/a.bin", bytes: 12_000, seed: 9)
        try FileManager.default.removeItem(atPath: src.path + "/dir/sub/b.bin")
        src.writeText("new.txt", "new")
        dst.writeText("extraneous.txt", "should be deleted")

        let second = try await FileSync.sync(from: src.url, to: dst.url)
        #expect(second.copiedFiles == 2, "只应复制变化的文件，实际 \(second.copiedFiles)")
        #expect(second.deletedItems == 2)
        #expect(fingerprint(src.path) == fingerprint(dst.path))
        #expect(try FileSync.summary(of: src.url) == FileSync.summary(of: dst.url))
    }

    /// 硬链接在目标端仍是同一个文件，而不是两份独立副本；再次同步不重复复制。
    @Test func hardLinksArePreserved() async throws {
        let src = TempDir("hl-src")
        src.write("data/orig.bin", bytes: 5_000_000, seed: 7)
        #expect(link(src.path + "/data/orig.bin", src.path + "/alias.bin") == 0)
        src.write("plain.bin", bytes: 1_000, seed: 8)
        let dst = TempDir("hl-dst")
        func inode(_ path: String) -> UInt64 {
            var st = stat()
            return lstat(path, &st) == 0 ? UInt64(st.st_ino) : 0
        }

        let first = try await FileSync.sync(from: src.url, to: dst.url)
        #expect(first.errors.isEmpty)
        #expect(first.copiedFiles == 3)
        #expect(inode(dst.path + "/data/orig.bin") == inode(dst.path + "/alias.bin"), "目标端应仍是同一个文件")
        #expect(fingerprint(src.path) == fingerprint(dst.path))
        #expect(try FileSync.summary(of: src.url) == FileSync.summary(of: dst.url))

        let second = try await FileSync.sync(from: src.url, to: dst.url)
        #expect(second.copiedFiles == 0 && second.errors.isEmpty, "没有变化就不该再复制")
        #expect(inode(dst.path + "/data/orig.bin") == inode(dst.path + "/alias.bin"))
    }

    /// 同大小的原地改写：文件数、总字节数都不变，只有修改时间变了，摘要必须能区分。
    @Test func summaryDetectsSameSizeRewrite() throws {
        let dir = TempDir("fp")
        dir.write("a.bin", bytes: 4096, seed: 1)
        dir.write("b.bin", bytes: 4096, seed: 2)
        let before = try FileSync.summary(of: dir.url)
        dir.write("a.bin", bytes: 4096, seed: 9)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: dir.path + "/a.bin")
        let after = try FileSync.summary(of: dir.url)
        #expect(before.sameCountsAndBytes(as: after))
        #expect(before != after, "修改时间变了，指纹应不同")
        // 顺序无关：同样的内容再算一次结果一致。
        #expect(try FileSync.summary(of: dir.url) == after)
    }

    /// 复制进度：大文件复制中持续上报，字节数单调递增，最终等于总量。
    @Test func progressIsMonotonicAndCompletes() async throws {
        let src = TempDir("psrc")
        src.write("big.bin", bytes: 24_000_000, seed: 5)
        src.write("small.bin", bytes: 1_000, seed: 6)
        let dst = TempDir("pdst")
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var events: [SyncProgress] = []
            func add(_ p: SyncProgress) { lock.lock(); events.append(p); lock.unlock() }
        }
        let log = Log()
        _ = try await FileSync.sync(from: src.url, to: dst.url) { log.add($0) }
        let copying = log.events.filter { $0.phase == .copying }
        #expect(zip(copying, copying.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone }, "进度不应倒退")
        #expect(copying.last?.bytesDone == 24_001_000)
        #expect(copying.allSatisfy { $0.bytesDone <= $0.bytesTotal })
        #expect(fingerprint(src.path) == fingerprint(dst.path))
    }

    @Test func selectiveSyncWithoutMirror() async throws {
        let src = makeSource()
        let dst = TempDir("dst")
        dst.writeText("keep.txt", "keep")
        let report = try await FileSync.sync(from: src.url, to: dst.url, options: SyncOptions(mirror: false, selection: ["dir/sub"]))
        #expect(report.errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dst.path + "/dir/sub/b.bin"))
        #expect(FileManager.default.fileExists(atPath: dst.path + "/dir/sub/文本.txt"))
        #expect(!FileManager.default.fileExists(atPath: dst.path + "/dir/a.bin"))
        #expect(!FileManager.default.fileExists(atPath: dst.path + "/big.bin"))
        #expect(FileManager.default.fileExists(atPath: dst.path + "/keep.txt"))
    }

    @Test func typeChangeIsHandled() async throws {
        let src = TempDir("src")
        let dst = TempDir("dst")
        src.writeText("x/inner.txt", "now a dir")
        dst.writeText("x", "was a file")
        let report = try await FileSync.sync(from: src.url, to: dst.url)
        #expect(report.errors.isEmpty)
        #expect(fingerprint(src.path) == fingerprint(dst.path))
    }
}

@Suite struct AnalyzerAndCleanupTests {
    @Test func analyzeCategoriesDuplicatesAndCleanup() async throws {
        let root = TempDir("an")
        root.write("videos/clip.mp4", bytes: 2_000_000)
        root.write("videos/clip-copy.mp4", bytes: 2_000_000)      // 与 clip.mp4 相同
        root.write("photos/a.jpg", bytes: 300_000, seed: 5)
        root.write("logs/app.log", bytes: 1_500_000, seed: 7)
        root.write("code/main.swift", bytes: 4_000, seed: 8)
        root.write("bundle.zip", bytes: 1_200_000, seed: 9)
        root.writeText(".fseventsd/x", "sys")

        let result = try await DiskAnalyzer.analyze(root: root.path)
        #expect(result.fileCount == 7)
        #expect(result.largestFiles.first?.name.hasPrefix("clip") == true)
        let byCat = Dictionary(uniqueKeysWithValues: result.categories.map { ($0.category, $0) })
        #expect(byCat[.video]?.count == 2)
        #expect(byCat[.image]?.count == 1)
        #expect(byCat[.archive]?.count == 1)
        #expect(byCat[.code]?.count == 2, "log 与 swift 都归为代码与数据")
        #expect(byCat[.system]?.count == 1)
        #expect(result.root.node(at: "videos")?.fileCount == 2)
        #expect(result.totalBytes == result.root.children.reduce(0) { $0 + $1.allocatedSize })

        let dupes = try await DiskAnalyzer.findDuplicates(in: result, minimumSize: 1)
        #expect(dupes.count == 1)
        #expect(Set(dupes[0].files.map(\.name)) == ["clip.mp4", "clip-copy.mp4"])

        var rule = CleanupRule(minimumSize: 1_000_000)
        rule.categories = [.code]
        let candidates = CleanupService.candidates(in: result, rule: rule)
        #expect(candidates.map(\.path) == ["logs/app.log"])
        rule = CleanupRule(minimumSize: 0, namePatterns: ["*.ZIP"])
        #expect(CleanupService.candidates(in: result, rule: rule).map(\.path) == ["bundle.zip"])
        rule = CleanupRule(minimumSize: 0, olderThan: 3600)
        #expect(CleanupService.candidates(in: result, rule: rule).isEmpty, "刚写入的文件不应算作旧文件")

        let dupCandidates = CleanupService.candidates(fromDuplicates: dupes)
        #expect(dupCandidates.count == 1)

        let report = await CleanupService.delete(relativePaths: ["logs/app.log", "../escape", ".fseventsd/x", "nope.txt"], root: root.path)
        #expect(report.deletedCount == 1)
        #expect(report.freedBytes >= 1_500_000)
        #expect(report.failures.count == 3)
        #expect(!FileManager.default.fileExists(atPath: root.path + "/logs/app.log"))
        #expect(FileManager.default.fileExists(atPath: root.path + "/.fseventsd/x"))
    }

    @Test func cleanupRefusesSymlinkEscape() async throws {
        let outside = TempDir("outside")
        outside.writeText("victim.txt", "must survive")
        let root = TempDir("root")
        root.symlink("evil", to: outside.path)
        let report = await CleanupService.delete(relativePaths: ["evil/victim.txt"], root: root.path)
        #expect(report.deletedCount == 0)
        #expect(FileManager.default.fileExists(atPath: outside.path + "/victim.txt"))
    }

    /// 卷外目录的路径恰好以卷路径开头（/Volumes/Cache 与 /Volumes/Cache2）：只比字符串前缀会放行。
    @Test func cleanupRefusesSiblingWithSamePrefix() async throws {
        let root = TempDir("root")
        let sibling = root.path + "2"
        try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sibling) }
        try Data("must survive".utf8).write(to: URL(fileURLWithPath: sibling + "/victim.txt"))
        root.symlink("evil", to: sibling)
        let report = await CleanupService.delete(relativePaths: ["evil/victim.txt"], root: root.path)
        #expect(report.deletedCount == 0)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: sibling + "/victim.txt"))
    }
}

@Suite struct CloneAwarenessTests {
    @Test func clonesAreNotCountedAsReclaimable() async throws {
        let root = TempDir("clone")
        root.write("a.bin", bytes: 2_000_000, seed: 3)
        #expect(clonefile(root.path + "/a.bin", root.path + "/clone.bin", 0) == 0, "临时目录应在 APFS 上")
        // FileManager.copyItem 在 APFS 上会克隆，这里按字节写出一份真实副本。
        try Data(contentsOf: URL(fileURLWithPath: root.path + "/a.bin")).write(to: URL(fileURLWithPath: root.path + "/copy-real.bin"))
        #expect(CloneInfo.privateSize(atPath: root.path + "/a.bin") == 0, "a.bin 与 clone.bin 共享数据")
        root.write("b.bin", bytes: 1_500_000, seed: 4)
        #expect(clonefile(root.path + "/b.bin", root.path + "/b-clone.bin", 0) == 0)

        #expect(CloneInfo.privateSize(atPath: root.path + "/clone.bin") == 0)
        #expect((CloneInfo.privateSize(atPath: root.path + "/copy-real.bin") ?? 0) >= 2_000_000)

        let result = try await DiskAnalyzer.analyze(root: root.path)
        let groups = try await DiskAnalyzer.findDuplicates(in: result, minimumSize: 1)
        #expect(groups.count == 2)
        let mixed = try #require(groups.first { $0.files.count == 3 })
        #expect(mixed.reclaimableBytes >= 2_000_000 && mixed.reclaimableBytes < 2_200_000, "只有真实副本可释放：\(mixed.reclaimableBytes)")
        #expect(!mixed.isCloneGroup)
        let clones = try #require(groups.first { $0.files.count == 2 })
        #expect(clones.reclaimableBytes == 0 && clones.isCloneGroup)

        let candidates = CleanupService.candidates(fromDuplicates: [clones])
        #expect(candidates.count == 1 && candidates[0].reclaimableBytes == 0)
        #expect(candidates[0].reasons.contains { $0.contains("克隆") })
    }
}
