import Darwin
import Foundation

public struct CleanupRule: Codable, Sendable, Hashable {
    public enum DateBasis: String, Codable, Sendable, CaseIterable, Identifiable {
        case modified, accessed
        public var id: String { rawValue }
        public var displayName: String { self == .modified ? "修改时间" : "访问时间" }
    }

    /// 只看不小于此大小的文件。
    public var minimumSize: UInt64
    /// 只看超过此时长未修改 / 未访问的文件；nil 表示不限。
    public var olderThan: TimeInterval?
    public var dateBasis: DateBasis
    /// 只看这些类别；空集合表示不限。
    public var categories: Set<FileCategory>
    /// 文件名通配（fnmatch），例如 "*.log"；空表示不限。
    public var namePatterns: [String]

    public init(minimumSize: UInt64 = 100 * ByteSize.mib, olderThan: TimeInterval? = nil, dateBasis: DateBasis = .modified,
                categories: Set<FileCategory> = [], namePatterns: [String] = []) {
        self.minimumSize = minimumSize
        self.olderThan = olderThan
        self.dateBasis = dateBasis
        self.categories = categories
        self.namePatterns = namePatterns
    }

    func matches(_ node: FileNode, now: Date) -> [String]? {
        guard !node.isDirectory, node.category != .system else { return nil }
        var reasons: [String] = []
        guard node.allocatedSize >= minimumSize else { return nil }
        if minimumSize > 0 { reasons.append("大小 \(ByteSize.format(node.allocatedSize))") }
        if let olderThan {
            let date = dateBasis == .modified ? node.modified : node.accessed
            let age = now.timeIntervalSince(date)
            guard age >= olderThan else { return nil }
            reasons.append("\(Int(age / 3600)) 小时未\(dateBasis == .modified ? "修改" : "访问")")
        }
        if !categories.isEmpty {
            guard categories.contains(node.category) else { return nil }
            reasons.append(node.category.displayName)
        }
        if !namePatterns.isEmpty {
            guard let hit = namePatterns.first(where: { fnmatch($0, node.name, FNM_CASEFOLD) == 0 }) else { return nil }
            reasons.append("匹配 \(hit)")
        }
        return reasons
    }
}

public struct CleanupCandidate: Sendable, Identifiable, Hashable {
    public let path: String
    public let name: String
    public let size: UInt64
    /// 单独删除它能释放的空间（APFS 克隆共享的部分不计）。
    public let reclaimableBytes: UInt64
    public let modified: Date
    public let accessed: Date
    public let category: FileCategory
    public let reasons: [String]

    public var id: String { path }
}

public struct CleanupReport: Sendable {
    public var deletedCount = 0
    /// 按文件独占空间估算的释放量。
    public var freedBytes: UInt64 = 0
    /// 删除前后卷可用空间之差（tmpfs 回收有延迟，可能偏小）。
    public var measuredFreedBytes: UInt64 = 0
    public var failures: [String] = []
}

public enum CleanupService {
    public static func candidates(in result: AnalysisResult, rule: CleanupRule, now: Date = Date()) -> [CleanupCandidate] {
        var list: [CleanupCandidate] = []
        result.root.forEachFile { node in
            guard var reasons = rule.matches(node, now: now) else { return }
            let reclaimable = CloneInfo.privateSize(atPath: result.absolutePath(node)) ?? node.allocatedSize
            if node.allocatedSize > 0, reclaimable < node.allocatedSize / 10 { reasons.append("APFS 克隆，删除基本不释放空间") }
            list.append(CleanupCandidate(path: node.path, name: node.name, size: node.allocatedSize, reclaimableBytes: reclaimable,
                                         modified: node.modified, accessed: node.accessed, category: node.category, reasons: reasons))
        }
        return list.sorted { $0.size > $1.size }
    }

    /// 重复文件：每组保留第一个（路径最短者），其余作为候选。
    public static func candidates(fromDuplicates groups: [DuplicateGroup]) -> [CleanupCandidate] {
        groups.flatMap { group -> [CleanupCandidate] in
            let sorted = group.files.sorted { ($0.path.count, $0.path) < ($1.path.count, $1.path) }
            guard let keep = sorted.first else { return [] }
            return sorted.dropFirst().map { node in
                var reasons = ["与 \(keep.path) 内容相同"]
                if group.isCloneGroup { reasons.append("APFS 克隆，删除基本不释放空间") }
                return CleanupCandidate(path: node.path, name: node.name, size: node.allocatedSize,
                                        reclaimableBytes: group.isCloneGroup ? 0 : node.allocatedSize, modified: node.modified,
                                        accessed: node.accessed, category: node.category, reasons: reasons)
            }
        }
    }

    /// 永久删除卷内的文件（RAM 盘没有废纸篓）。只接受卷内相对路径，拒绝越界。
    public static func delete(relativePaths: [String], root: String) async -> CleanupReport {
        await Task.detached {
            var report = CleanupReport()
            let rootPath = MountTable.normalize(root)
            let freeBefore = MountTable.entry(at: rootPath)?.availableBytes ?? 0
            for rel in relativePaths {
                let clean = PathSelection.clean(rel)
                guard !clean.isEmpty, !clean.split(separator: "/").contains("..") else {
                    report.failures.append("\(rel)：非法路径")
                    continue
                }
                if VolumeSpecialItems.isSpecial(relativePath: clean) {
                    report.failures.append("\(rel)：系统条目，跳过")
                    continue
                }
                let full = rootPath + "/" + clean
                // 父目录解析后必须仍在卷内（防止经由符号链接目录删到卷外）。
                let parent = ((full as NSString).deletingLastPathComponent as NSString).resolvingSymlinksInPath
                guard MountTable.normalize(parent).hasPrefix(rootPath) else {
                    report.failures.append("\(rel)：路径越界")
                    continue
                }
                var st = stat()
                guard lstat(full, &st) == 0 else {
                    report.failures.append("\(rel)：文件不存在")
                    continue
                }
                let estimate = CloneInfo.privateSize(atPath: full) ?? UInt64(st.st_blocks) * 512
                do {
                    try FileManager.default.removeItem(atPath: full)
                    report.deletedCount += 1
                    report.freedBytes += estimate
                } catch {
                    report.failures.append("\(rel)：\(error.localizedDescription)")
                }
            }
            let freeAfter = MountTable.entry(at: rootPath)?.availableBytes ?? 0
            report.measuredFreedBytes = freeAfter > freeBefore ? freeAfter - freeBefore : 0
            return report
        }.value
    }
}
