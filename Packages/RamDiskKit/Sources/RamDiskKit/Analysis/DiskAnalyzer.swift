import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

public enum FileCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case video, image, audio, archive, diskImage, document, code, application, system, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .video: return "视频"
        case .image: return "图片"
        case .audio: return "音频"
        case .archive: return "压缩包"
        case .diskImage: return "磁盘映像"
        case .document: return "文档"
        case .code: return "代码与数据"
        case .application: return "应用与库"
        case .system: return "系统文件"
        case .other: return "其他"
        }
    }

    static func classify(name: String, isSystem: Bool) -> FileCategory {
        if isSystem { return .system }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        switch ext {
        case "dmg", "iso", "img", "sparseimage", "sparsebundle", "asif", "vmdk", "qcow2", "vdi": return .diskImage
        case "aea", "aar", "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "zst", "lz4", "cpio", "xip": return .archive
        case "app", "dylib", "framework", "so", "a", "o", "pkg", "ipa", "apk", "exe": return .application
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml)
            || type.conforms(to: .database) || type.conforms(to: .log) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .text) || type.conforms(to: .compositeContent) { return .document }
        if type.conforms(to: .executable) || type.conforms(to: .bundle) { return .application }
        return .other
    }
}

/// 扫描得到的目录树节点（构建完成后不可变）。
public final class FileNode: Identifiable, @unchecked Sendable {
    public let name: String
    /// 相对卷根的路径；根节点为空串。
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// 实际占用（st_blocks × 512），目录为子项之和。
    public private(set) var allocatedSize: UInt64
    /// 文件逻辑大小，目录为子项之和。
    public private(set) var logicalSize: UInt64
    public let modified: Date
    public let accessed: Date
    public let category: FileCategory
    public private(set) var children: [FileNode]
    public private(set) var fileCount: Int

    public var id: String { path }

    init(name: String, path: String, isDirectory: Bool, isSymlink: Bool, allocated: UInt64, logical: UInt64,
         modified: Date, accessed: Date, category: FileCategory) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        allocatedSize = allocated
        logicalSize = logical
        self.modified = modified
        self.accessed = accessed
        self.category = category
        children = []
        fileCount = isDirectory ? 0 : 1
    }

    fileprivate func finalize(children list: [FileNode]) {
        children = list.sorted { $0.allocatedSize > $1.allocatedSize }
        allocatedSize += list.reduce(0) { $0 + $1.allocatedSize }
        logicalSize += list.reduce(0) { $0 + $1.logicalSize }
        fileCount = list.reduce(0) { $0 + $1.fileCount }
    }

    /// 按相对路径查找子节点。
    public func node(at relativePath: String) -> FileNode? {
        if relativePath.isEmpty { return self }
        var current: FileNode = self
        for component in relativePath.split(separator: "/") {
            guard let next = current.children.first(where: { $0.name == component }) else { return nil }
            current = next
        }
        return current
    }

    /// 深度优先遍历所有文件（不含目录）。
    public func forEachFile(_ body: (FileNode) -> Void) {
        if !isDirectory { body(self); return }
        for child in children { child.forEachFile(body) }
    }
}

public struct CategoryStat: Sendable, Identifiable, Hashable {
    public let category: FileCategory
    public let bytes: UInt64
    public let count: Int
    public var id: FileCategory { category }
}

public struct AnalysisResult: Sendable {
    public let rootPath: String
    public let root: FileNode
    public let scannedAt: Date
    public let duration: TimeInterval
    public let fileCount: Int
    public let directoryCount: Int
    public let categories: [CategoryStat]
    public let largestFiles: [FileNode]
    public let largestDirectories: [FileNode]

    public var totalBytes: UInt64 { root.allocatedSize }

    public func absolutePath(_ node: FileNode) -> String {
        node.path.isEmpty ? rootPath : rootPath + "/" + node.path
    }
}

public struct DuplicateGroup: Sendable, Identifiable {
    public let id = UUID()
    public let size: UInt64
    public let files: [FileNode]
    /// 重复内容的总量（保留一份）。
    public var wastedBytes: UInt64 { size * UInt64(max(0, files.count - 1)) }
    /// 保留路径最短的一份、删除其余后实际能释放的空间：APFS 克隆共享数据块，删除不释放。
    public let reclaimableBytes: UInt64

    init(size: UInt64, files: [FileNode], root: String) {
        self.size = size
        self.files = files
        let others = files.sorted { ($0.path.count, $0.path) < ($1.path.count, $1.path) }.dropFirst()
        reclaimableBytes = others.reduce(0) { $0 + (CloneInfo.privateSize(atPath: root + "/" + $1.path) ?? $1.allocatedSize) }
    }

    /// 组内文件互为 APFS 克隆（几乎不占额外空间）。
    public var isCloneGroup: Bool { wastedBytes > 0 && reclaimableBytes < wastedBytes / 10 }
}

public enum DiskAnalyzer {
    /// 扫描整个卷。`progress` 回调已扫描的条目数。
    public static func analyze(root: String, topCount: Int = 200, progress: (@Sendable (Int) -> Void)? = nil) async throws -> AnalysisResult {
        try await Task.detached(priority: .userInitiated) {
            try scan(root: root, topCount: topCount, progress: progress)
        }.value
    }

    static func scan(root: String, topCount: Int, progress: (@Sendable (Int) -> Void)?) throws -> AnalysisResult {
        let start = Date()
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root]) }
        let rootNode = FileNode(name: (root as NSString).lastPathComponent, path: "", isDirectory: true, isSymlink: false,
                                allocated: 0, logical: 0, modified: date(rootStat.st_mtimespec), accessed: date(rootStat.st_atimespec),
                                category: .other)
        var visited = 0
        var directories = 0
        let rootDevice = rootStat.st_dev
        try build(node: rootNode, absolute: root, device: rootDevice, visited: &visited, directories: &directories, progress: progress)

        var files: [FileNode] = []
        rootNode.forEachFile { files.append($0) }
        var stats: [FileCategory: (UInt64, Int)] = [:]
        for f in files {
            let s = stats[f.category] ?? (0, 0)
            stats[f.category] = (s.0 + f.allocatedSize, s.1 + 1)
        }
        let categories = stats.map { CategoryStat(category: $0.key, bytes: $0.value.0, count: $0.value.1) }
            .sorted { $0.bytes > $1.bytes }
        let largest = Array(files.sorted { $0.allocatedSize > $1.allocatedSize }.prefix(topCount))
        var dirs: [FileNode] = []
        func collectDirs(_ n: FileNode) {
            for c in n.children where c.isDirectory {
                dirs.append(c)
                collectDirs(c)
            }
        }
        collectDirs(rootNode)
        let largestDirs = Array(dirs.sorted { $0.allocatedSize > $1.allocatedSize }.prefix(50))

        return AnalysisResult(rootPath: root, root: rootNode, scannedAt: Date(), duration: Date().timeIntervalSince(start),
                              fileCount: files.count, directoryCount: directories, categories: categories,
                              largestFiles: largest, largestDirectories: largestDirs)
    }

    private static func build(node: FileNode, absolute: String, device: dev_t, visited: inout Int, directories: inout Int,
                              progress: (@Sendable (Int) -> Void)?) throws {
        guard let dir = opendir(absolute) else { return }
        var children: [FileNode] = []
        var subdirs: [(FileNode, String)] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let childAbs = absolute + "/" + name
            var st = stat()
            guard lstat(childAbs, &st) == 0 else { continue }
            let rel = node.path.isEmpty ? name : node.path + "/" + name
            let type = st.st_mode & S_IFMT
            let isDir = type == S_IFDIR
            let isSystem = VolumeSpecialItems.isSpecial(relativePath: rel)
            let child = FileNode(
                name: name, path: rel, isDirectory: isDir, isSymlink: type == S_IFLNK,
                allocated: isDir ? 0 : UInt64(st.st_blocks) * 512,
                logical: isDir ? 0 : UInt64(max(0, st.st_size)),
                modified: date(st.st_mtimespec), accessed: date(st.st_atimespec),
                category: isDir ? (isSystem ? .system : .other) : FileCategory.classify(name: name, isSystem: isSystem)
            )
            children.append(child)
            visited += 1
            if visited % 2000 == 0 {
                progress?(visited)
                try Task.checkCancellation()
            }
            // 不跨越到其他挂载的文件系统。
            if isDir, st.st_dev == device { subdirs.append((child, childAbs)) }
        }
        closedir(dir)
        for (child, path) in subdirs {
            directories += 1
            try build(node: child, absolute: path, device: device, visited: &visited, directories: &directories, progress: progress)
        }
        node.finalize(children: children)
    }

    static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }

    // MARK: - 重复文件

    /// 找出内容完全相同的文件：先按大小分组，再比较头部 64KB 的哈希，最后比较完整 SHA-256。
    public static func findDuplicates(in result: AnalysisResult, minimumSize: UInt64 = 1024 * 1024,
                                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> [DuplicateGroup] {
        try await Task.detached(priority: .userInitiated) {
            var bySize: [UInt64: [FileNode]] = [:]
            result.root.forEachFile { node in
                guard !node.isSymlink, node.category != .system, node.logicalSize >= minimumSize else { return }
                bySize[node.logicalSize, default: []].append(node)
            }
            let candidates = bySize.filter { $0.value.count > 1 }
            var groups: [DuplicateGroup] = []
            var done = 0
            for (size, nodes) in candidates {
                try Task.checkCancellation()
                var byHead: [Data: [FileNode]] = [:]
                for node in nodes {
                    if let h = hash(path: result.absolutePath(node), limit: 64 * 1024) { byHead[h, default: []].append(node) }
                }
                for (_, sameHead) in byHead where sameHead.count > 1 {
                    if size <= 64 * 1024 {
                        groups.append(DuplicateGroup(size: size, files: sameHead, root: result.rootPath))
                        continue
                    }
                    var byFull: [Data: [FileNode]] = [:]
                    for node in sameHead {
                        if let h = hash(path: result.absolutePath(node), limit: nil) { byFull[h, default: []].append(node) }
                    }
                    for (_, same) in byFull where same.count > 1 {
                        groups.append(DuplicateGroup(size: size, files: same.sorted { $0.path < $1.path }, root: result.rootPath))
                    }
                }
                done += 1
                progress?(Double(done) / Double(max(1, candidates.count)))
            }
            return groups.sorted { ($0.reclaimableBytes, $0.wastedBytes) > ($1.reclaimableBytes, $1.wastedBytes) }
        }.value
    }

    static func hash(path: String, limit: Int?) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = (try? handle.read(upToCount: min(1 << 20, remaining))) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return Data(hasher.finalize())
    }
}
