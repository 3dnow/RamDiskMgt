import Darwin
import Foundation

public struct SyncProgress: Sendable {
    public enum Phase: String, Sendable { case scanning, copying, deleting, finishing }
    public var phase: Phase
    public var filesTotal: Int
    public var filesDone: Int
    public var bytesTotal: UInt64
    public var bytesDone: UInt64
    public var currentPath: String

    public var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        return filesTotal == 0 ? 1 : min(1, Double(filesDone) / Double(filesTotal))
    }
}

public struct SyncReport: Sendable {
    public var copiedFiles = 0
    public var copiedBytes: UInt64 = 0
    /// 有文件因目标空间不足复制失败。
    public var outOfSpace = false
    public var failedBytes: UInt64 = 0
    public var unchangedFiles = 0
    public var deletedItems = 0
    public var errors: [String] = []
}

/// 一棵目录树的摘要，用于迁移后校验。
public struct TreeSummary: Sendable, Equatable {
    public var files = 0
    public var directories = 0
    public var symlinks = 0
    public var bytes: UInt64 = 0
}

public struct SyncOptions: Sendable {
    /// 删除目标里源端没有的条目（镜像模式）。
    public var mirror: Bool
    /// 只同步这些相对路径（文件或目录）；nil 表示全部。
    public var selection: [String]?
    /// 并发复制的文件数。
    public var parallelism: Int

    public init(mirror: Bool = true, selection: [String]? = nil, parallelism: Int = 8) {
        self.mirror = mirror
        self.selection = selection
        self.parallelism = parallelism
    }
}

/// 文件树条目（lstat 语义，不跟随符号链接）。
struct TreeItem: Sendable {
    enum Kind: Sendable { case file, directory, symlink, other }
    let path: String          // 相对路径
    let kind: Kind
    let size: UInt64
    let mtime: timespec
}

/// 选择集合：判断相对路径是否被选中，或是被选中路径的祖先目录。
public struct PathSelection: Sendable {
    public let paths: [String]

    public init(_ paths: [String]) {
        self.paths = paths.map(Self.clean).filter { !$0.isEmpty }
    }

    static func clean(_ p: String) -> String {
        var s = p
        while s.hasPrefix("/") || s.hasPrefix("./") { s.removeFirst(s.hasPrefix("/") ? 1 : 2) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 自身被选中，或位于某个被选中的目录内。
    public func contains(_ path: String) -> Bool {
        paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// 是某个被选中路径的祖先目录（需要进入但不整体包含）。
    public func isAncestor(_ path: String) -> Bool {
        path.isEmpty || paths.contains { $0.hasPrefix(path + "/") }
    }

    public func shouldVisit(_ path: String) -> Bool { contains(path) || isAncestor(path) }
}

public enum FileSync {
    /// 把 `source` 同步到 `destination`：只复制大小或修改时间不同的文件，保留权限、时间、扩展属性。
    public static func sync(
        from source: URL,
        to destination: URL,
        options: SyncOptions = SyncOptions(),
        progress: (@Sendable (SyncProgress) -> Void)? = nil
    ) async throws -> SyncReport {
        let src = source.path
        let dst = destination.path
        let selection = options.selection.map(PathSelection.init)

        progress?(SyncProgress(phase: .scanning, filesTotal: 0, filesDone: 0, bytesTotal: 0, bytesDone: 0, currentPath: ""))
        let sourceItems = try scan(root: src, selection: selection)
        try Task.checkCancellation()
        let destItems = (try? scan(root: dst, selection: selection)) ?? []
        var destIndex: [String: TreeItem] = [:]
        for item in destItems { destIndex[item.path] = item }

        var report = SyncReport()
        var copyJobs: [TreeItem] = []
        var directories: [TreeItem] = []

        // 目录与符号链接先串行处理，文件放入并发队列。
        for item in sourceItems {
            let target = dst + "/" + item.path
            let existing = destIndex[item.path]
            if let existing, existing.kind != item.kind {
                try removeItem(atPath: target)
                destIndex[item.path] = nil
            }
            switch item.kind {
            case .directory:
                if destIndex[item.path] == nil {
                    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
                }
                directories.append(item)
            case .symlink:
                let srcLink = try? FileManager.default.destinationOfSymbolicLink(atPath: src + "/" + item.path)
                let dstLink = try? FileManager.default.destinationOfSymbolicLink(atPath: target)
                if srcLink != dstLink || destIndex[item.path] == nil {
                    if destIndex[item.path] != nil { try removeItem(atPath: target) }
                    try copyItem(from: src + "/" + item.path, to: target)
                    report.copiedFiles += 1
                } else {
                    report.unchangedFiles += 1
                }
            case .file:
                if let existing = destIndex[item.path], existing.size == item.size, sameTime(existing.mtime, item.mtime) {
                    report.unchangedFiles += 1
                } else {
                    copyJobs.append(item)
                }
            case .other:
                break
            }
        }

        let bytesTotal = copyJobs.reduce(UInt64(0)) { $0 + $1.size }
        var state = SyncProgress(phase: .copying, filesTotal: copyJobs.count, filesDone: 0, bytesTotal: bytesTotal, bytesDone: 0, currentPath: "")
        progress?(state)

        let parallelism = max(1, options.parallelism)
        var errors: [String] = []
        var outOfSpace = false
        var failedBytes: UInt64 = 0
        try await withThrowingTaskGroup(of: (TreeItem, String?, Bool).self) { group in
            var iterator = copyJobs.makeIterator()
            func addNext() -> Bool {
                guard let job = iterator.next() else { return false }
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        try copyItem(from: src + "/" + job.path, to: dst + "/" + job.path)
                        return (job, nil, false)
                    } catch {
                        return (job, "\(job.path)：\(error.localizedDescription)", RestoreSizing.isOutOfSpace(error))
                    }
                }
                return true
            }
            for _ in 0..<parallelism where !addNext() { break }
            while let (job, error, noSpace) = try await group.next() {
                if let error {
                    errors.append(error)
                    failedBytes += job.size
                    if noSpace { outOfSpace = true }
                } else {
                    report.copiedFiles += 1
                    report.copiedBytes += job.size
                }
                state.filesDone += 1
                state.bytesDone += job.size
                state.currentPath = job.path
                progress?(state)
                _ = addNext()
            }
        }
        report.errors += errors
        report.outOfSpace = outOfSpace
        report.failedBytes = failedBytes

        if options.mirror {
            state.phase = .deleting
            progress?(state)
            let sourcePaths = Set(sourceItems.map(\.path))
            // 先删深层路径，避免删除父目录后子项报错。
            let extraneous = destItems.map(\.path)
                .filter { !sourcePaths.contains($0) && !VolumeSpecialItems.isSpecial(relativePath: $0) }
                .sorted { $0.count > $1.count }
            for path in extraneous where FileManager.default.fileExists(atPath: dst + "/" + path) || isSymlink(dst + "/" + path) {
                do {
                    try removeItem(atPath: dst + "/" + path)
                    report.deletedItems += 1
                } catch {
                    report.errors.append("\(path)：\(error.localizedDescription)")
                }
            }
        }

        // 最后回写目录元数据（复制文件会改动目录的修改时间）。
        state.phase = .finishing
        progress?(state)
        for dir in directories.reversed() {
            _ = copyfile(src + "/" + dir.path, dst + "/" + dir.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_ACL))
        }
        return report
    }

    /// 统计目录树（跳过卷根的系统条目）。
    public static func summary(of root: URL, selection: [String]? = nil) throws -> TreeSummary {
        var s = TreeSummary()
        for item in try scan(root: root.path, selection: selection.map(PathSelection.init)) {
            switch item.kind {
            case .file: s.files += 1; s.bytes += item.size
            case .directory: s.directories += 1
            case .symlink: s.symlinks += 1
            case .other: break
            }
        }
        return s
    }

    // MARK: - 内部实现

    static func scan(root: String, selection: PathSelection?) throws -> [TreeItem] {
        var items: [TreeItem] = []
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root])
        }
        try walk(root: root, relative: "", selection: selection, into: &items)
        return items
    }

    private static func walk(root: String, relative: String, selection: PathSelection?, into items: inout [TreeItem]) throws {
        let dirPath = relative.isEmpty ? root : root + "/" + relative
        guard let dir = opendir(dirPath) else { return }
        defer { closedir(dir) }
        var subdirs: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let len = Int(entry.pointee.d_namlen)
                return String(decoding: raw.prefix(len), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            if relative.isEmpty, VolumeSpecialItems.isSpecial(rootLevelName: name) { continue }
            let rel = relative.isEmpty ? name : relative + "/" + name
            if let selection, !selection.shouldVisit(rel) { continue }
            var st = stat()
            guard lstat(root + "/" + rel, &st) == 0 else { continue }
            let kind: TreeItem.Kind
            switch st.st_mode & S_IFMT {
            case S_IFDIR: kind = .directory
            case S_IFREG: kind = .file
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            // 祖先目录本身只在“被选中或位于选中目录内”时才算作条目，但仍要进入。
            if let selection, kind != .directory, !selection.contains(rel) { continue }
            items.append(TreeItem(path: rel, kind: kind, size: kind == .file ? UInt64(st.st_size) : 0, mtime: st.st_mtimespec))
            if kind == .directory { subdirs.append(rel) }
        }
        for sub in subdirs {
            try Task.checkCancellation()
            try walk(root: root, relative: sub, selection: selection, into: &items)
        }
    }

    static func sameTime(_ a: timespec, _ b: timespec) -> Bool {
        a.tv_sec == b.tv_sec && abs(a.tv_nsec - b.tv_nsec) < 1_000_000
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// 复制单个文件或符号链接（不跟随链接），保留全部元数据，目标已存在时先删除。
    static func copyItem(from: String, to: String) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_UNLINK)
        if copyfile(from, to, nil, flags) != 0 {
            var code = errno
            if code == ENOENT {
                // 父目录可能尚未创建（选择性同步时）。
                try FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if copyfile(from, to, nil, flags) == 0 { return }
                code = errno
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    static func removeItem(atPath path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}
