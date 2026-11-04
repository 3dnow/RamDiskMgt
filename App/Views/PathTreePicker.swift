import RamDiskKit
import SwiftUI

/// 可勾选的路径树节点。
final class PathTree: Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool
    var size: UInt64
    var children: [PathTree]?

    var id: String { path }

    init(path: String, name: String, isDirectory: Bool, size: UInt64, children: [PathTree]? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
    }

    /// 由扁平的备份条目列表构建树（目录大小为子项之和）。
    static func build(from entries: [ArchiveEntry]) -> [PathTree] {
        let root = PathTree(path: "", name: "", isDirectory: true, size: 0, children: [])
        var index: [String: PathTree] = ["": root]
        func node(for path: String, isDirectory: Bool, size: UInt64) -> PathTree {
            if let existing = index[path] {
                if !isDirectory { existing.size = size }
                return existing
            }
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent = node(for: parentPath, isDirectory: true, size: 0)
            let n = PathTree(path: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory, size: size,
                             children: isDirectory ? [] : nil)
            parent.children?.append(n)
            index[path] = n
            return n
        }
        for e in entries.sorted(by: { $0.path < $1.path }) { _ = node(for: e.path, isDirectory: e.isDirectory, size: e.size) }
        func finalize(_ n: PathTree) -> UInt64 {
            guard var kids = n.children else { return n.size }
            n.size = kids.reduce(0) { $0 + finalize($1) }
            kids.sort { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
            n.children = kids.isEmpty ? nil : kids
            return n.size
        }
        _ = finalize(root)
        return root.children ?? []
    }

    /// 由分析结果构建（只取前若干层，避免超大目录卡顿）。
    static func build(from node: FileNode, depth: Int = 6) -> [PathTree] {
        func convert(_ n: FileNode, _ level: Int) -> PathTree {
            let kids: [PathTree]? = n.isDirectory && level < depth
                ? n.children.filter { $0.category != .system }.prefix(500).map { convert($0, level + 1) }
                : nil
            return PathTree(path: n.path, name: n.name, isDirectory: n.isDirectory, size: n.allocatedSize,
                            children: (kids?.isEmpty ?? true) ? nil : kids)
        }
        return node.children.filter { $0.category != .system }.map { convert($0, 1) }
    }
}

/// 勾选目录即包含其全部内容。
struct PathTreePicker: View {
    let roots: [PathTree]
    @Binding var selection: Set<String>

    var body: some View {
        List {
            OutlineGroup(roots, children: \.children) { node in
                let inherited = isSelectedByAncestor(node.path)
                Toggle(isOn: Binding(
                    get: { inherited || selection.contains(node.path) },
                    set: { on in toggle(node.path, on: on) }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: node.isDirectory ? "folder" : "doc")
                            .appFont(.body)
                            .foregroundStyle(.secondary)
                        Text(node.name).appFont(.body).lineLimit(1)
                        Spacer()
                        Text(ByteSize.format(node.size)).appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(inherited)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    private func isSelectedByAncestor(_ path: String) -> Bool {
        selection.contains { path.hasPrefix($0 + "/") }
    }

    private func toggle(_ path: String, on: Bool) {
        if on {
            selection = selection.filter { !$0.hasPrefix(path + "/") }
            selection.insert(path)
        } else {
            selection.remove(path)
        }
    }
}
