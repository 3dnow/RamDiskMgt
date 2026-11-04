import Charts
import RamDiskKit
import SwiftUI

struct AnalysisTab: View {
    @Environment(AppModel.self) private var model
    let disk: RamDisk
    @State private var currentPath = ""
    @State private var listMode: ListMode = .files

    enum ListMode: String, CaseIterable, Identifiable {
        case files, directories, categories
        var id: String { rawValue }
        var title: String {
            switch self {
            case .files: return "最大文件"
            case .directories: return "最大目录"
            case .categories: return "按类型"
            }
        }
    }

    var body: some View {
        let state = model.analysis(for: disk)
        Group {
            if let result = state.result {
                content(result, state: state)
            } else if state.scanning {
                ProgressView { Text("正在扫描… 已读取 \(state.scanned) 项").appFont(.body) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(title: "尚未分析", symbol: "chart.pie",
                           message: state.error ?? "扫描整个卷，按占用大小和类型展示，找出最占空间的文件和目录。") {
                    Button("开始分析") { model.analyze(disk) }
                        .scaledButtonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            if state.result == nil, !state.scanning { model.analyze(disk) }
        }
    }

    @ViewBuilder
    private func content(_ result: AnalysisResult, state: AnalysisState) -> some View {
        let current = result.root.node(at: currentPath) ?? result.root
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Breadcrumb(path: currentPath) { currentPath = $0 }
                Spacer()
                Text("\(result.fileCount) 个文件 · \(ByteSize.format(result.totalBytes)) · 扫描于\(result.scannedAt.shortRelative)")
                    .appFont(.caption).foregroundStyle(.secondary)
                Button {
                    model.analyze(disk)
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(state.scanning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    TreemapView(node: current, rootPath: result.rootPath) { child in
                        if child.isDirectory { currentPath = child.path }
                    }
                    .scaledFrame(minWidth: 360, minHeight: 280)
                    CategoryLegend(categories: result.categories)
                }
                .padding(12)
                .scaledFrame(minWidth: 420)

                VStack(spacing: 8) {
                    SegmentedTabs(selection: $listMode, items: ListMode.allCases.map { ($0, $0.title) })
                    switch listMode {
                    case .files: LargestFilesTable(result: result)
                    case .directories: LargestDirectoriesTable(result: result) { currentPath = $0 }
                    case .categories: CategoryChart(categories: result.categories)
                    }
                }
                .padding(12)
                .scaledFrame(minWidth: 320, idealWidth: 400)
            }
        }
    }
}

struct Breadcrumb: View {
    let path: String
    let onSelect: (String) -> Void

    var body: some View {
        let parts = path.split(separator: "/").map(String.init)
        HStack(spacing: 4) {
            Button("卷根") { onSelect("") }
                .scaledButtonStyle(.link)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right").appFont(.caption2).foregroundStyle(.tertiary)
                Button(part) { onSelect(parts.prefix(index + 1).joined(separator: "/")) }
                    .scaledButtonStyle(.link)
                    .lineLimit(1)
            }
        }
        .appFont(.callout)
    }
}

// MARK: - Treemap

struct TreemapView: View {
    let node: FileNode
    let rootPath: String
    let onOpen: (FileNode) -> Void
    @State private var hovered: FileNode?
    @State private var hoverPoint: CGPoint = .zero
    @State private var cache = LayoutCache()
    @Environment(\.fontScale) private var scale

    /// 布局与目录主色只在节点或尺寸变化时重算（悬停会频繁触发 body）。
    final class LayoutCache {
        var key = ""
        var cells: [PlacedCell] = []
    }

    private static let maxItems = 300

    var body: some View {
        GeometryReader { geo in
            let cells = cachedLayout(in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for cell in cells {
                        let rect = cell.rect.insetBy(dx: 1, dy: 1)  // 相邻色块之间留 2px 表面间隙
                        guard rect.width > 0.5, rect.height > 0.5 else { continue }
                        let path = Path(roundedRect: rect, cornerRadius: min(4, rect.width / 4, rect.height / 4))
                        context.fill(path, with: .color(fill(cell)))
                        if cell.node.id == hovered?.id {
                            context.stroke(path, with: .color(.primary), lineWidth: 2)
                        }
                        if rect.width > 54 * scale, rect.height > 30 * scale {
                            let title = Text(cell.node.name).font(.system(size: 11 * scale, weight: .medium))
                                .foregroundStyle(labelColor(cell))
                            let size = Text(ByteSize.format(cell.node.allocatedSize)).font(.system(size: 10 * scale))
                                .foregroundStyle(labelColor(cell).opacity(0.85))
                            var labelContext = context
                            labelContext.clip(to: Path(rect.insetBy(dx: 5, dy: 4)))
                            labelContext.draw(title, at: CGPoint(x: rect.minX + 6, y: rect.minY + 5), anchor: .topLeading)
                            if rect.height > 44 * scale {
                                labelContext.draw(size, at: CGPoint(x: rect.minX + 6, y: rect.minY + 6 + 14 * scale), anchor: .topLeading)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverPoint = point
                        hovered = cells.first { $0.rect.contains(point) }?.node
                    case .ended:
                        hovered = nil
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    if let hit = cells.first(where: { $0.rect.contains(value.location) })?.node { onOpen(hit) }
                })
                .contextMenu {
                    if let hovered {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rootPath + "/" + hovered.path)])
                        }
                    }
                }

                if let hovered {
                    TreemapTooltip(node: hovered)
                        .offset(tooltipOffset(in: geo.size))
                        .allowsHitTesting(false)
                }
                if cells.isEmpty {
                    Text("空目录").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("\(node.name) 的占用分布图，共 \(node.children.count) 项")
    }

    struct PlacedCell {
        let node: FileNode
        let rect: CGRect
        /// 文件为自身类别；目录为其内部占用最多的类别。
        let category: FileCategory
    }

    private func cachedLayout(in rect: CGRect) -> [PlacedCell] {
        let key = "\(node.id)|\(Int(rect.width))x\(Int(rect.height))|\(node.allocatedSize)"
        if cache.key == key { return cache.cells }
        let children = Array(node.children.filter { $0.allocatedSize > 0 }.prefix(Self.maxItems))
        let index = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
        let cells = Treemap.layout(children.map { (id: $0.id, value: Double($0.allocatedSize)) }, in: rect)
            .compactMap { cell -> PlacedCell? in
                guard let n = index[cell.id] else { return nil }
                return PlacedCell(node: n, rect: cell.rect, category: n.isDirectory ? Self.dominantCategory(n) : n.category)
            }
        cache.key = key
        cache.cells = cells
        return cells
    }

    private func fill(_ cell: PlacedCell) -> Color {
        let color = Theme.color(for: cell.category)
        return cell.node.isDirectory && cell.category != .system ? color.opacity(0.75) : color
    }

    private func labelColor(_ cell: PlacedCell) -> Color {
        Theme.labelColor(for: cell.category)
    }

    static func dominantCategory(_ node: FileNode) -> FileCategory {
        if node.category == .system { return .system }
        var totals: [FileCategory: UInt64] = [:]
        var visited = 0
        func walk(_ n: FileNode) {
            guard visited < 5000 else { return }
            visited += 1
            if n.isDirectory { n.children.forEach(walk) } else { totals[n.category, default: 0] += n.allocatedSize }
        }
        walk(node)
        return totals.max { $0.value < $1.value }?.key ?? .other
    }

    private func tooltipOffset(in size: CGSize) -> CGSize {
        let w: CGFloat = 240 * scale, h: CGFloat = 80 * scale
        let x = hoverPoint.x + 14 + w > size.width ? hoverPoint.x - w - 10 : hoverPoint.x + 14
        let y = hoverPoint.y + 14 + h > size.height ? hoverPoint.y - h - 10 : hoverPoint.y + 14
        return CGSize(width: max(0, x), height: max(0, y))
    }
}

struct TreemapTooltip: View {
    let node: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(node.name).appFont(.callout, weight: .semibold).lineLimit(1)
            Text(node.isDirectory ? "目录 · \(node.fileCount) 个文件" : node.category.displayName)
                .appFont(.caption).foregroundStyle(.secondary)
            Text("占用 \(ByteSize.format(node.allocatedSize))" + (node.isDirectory ? "" : " · 修改于 \(node.modified.shortRelative)"))
                .appFont(.caption).monospacedDigit()
            if node.isDirectory {
                Text("点击进入").appFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .scaledFrame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

struct CategoryLegend: View {
    let categories: [CategoryStat]

    var body: some View {
        let shown = FileCategory.allCases.filter { c in categories.contains { $0.category == c } }
        FlowLayout(spacing: 10) {
            ForEach(shown) { c in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: c)).scaledFrame(width: 10, height: 10)
                    Text(c.displayName).appFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 简单的换行布局。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + 4; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + 4; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 列表与图表

struct LargestFilesTable: View {
    @Environment(\.fontScale) private var scale
    let result: AnalysisResult

    var body: some View {
        Table(result.largestFiles) {
            TableColumn("文件") { node in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: node.category)).scaledFrame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).lineLimit(1)
                        Text((node.path as NSString).deletingLastPathComponent).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contextMenu {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.absolutePath(node))])
                    }
                }
            }
            TableColumn("占用") { node in
                Text(ByteSize.format(node.allocatedSize)).monospacedDigit()
            }
            .width(min: 70 * scale, ideal: 80 * scale, max: 100 * scale)
        }
    }
}

struct LargestDirectoriesTable: View {
    @Environment(\.fontScale) private var scale
    let result: AnalysisResult
    let onOpen: (String) -> Void

    var body: some View {
        Table(result.largestDirectories) {
            TableColumn("目录") { node in
                Button(node.path) { onOpen(node.path) }.scaledButtonStyle(.link).lineLimit(1)
            }
            TableColumn("文件数") { node in Text("\(node.fileCount)").monospacedDigit() }
                .width(min: 50 * scale, ideal: 60 * scale, max: 80 * scale)
            TableColumn("占用") { node in Text(ByteSize.format(node.allocatedSize)).monospacedDigit() }
                .width(min: 70 * scale, ideal: 80 * scale, max: 100 * scale)
        }
    }
}

/// 按类型的占用：横向条形图，直接标注数值，颜色跟随类别（与 treemap 一致）。
struct CategoryChart: View {
    @Environment(\.fontScale) private var scale
    let categories: [CategoryStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(categories) { stat in
                BarMark(x: .value("占用", Double(stat.bytes)), y: .value("类型", stat.category.displayName), height: .fixed(14 * scale))
                    .foregroundStyle(Theme.color(for: stat.category))
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .trailing, spacing: 4) {
                        Text(ByteSize.format(stat.bytes)).appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(ByteSize.format(UInt64(max(0, v)))).appFont(.caption2) }
                    }
                }
            }
            .chartYAxis { AxisMarks { AxisValueLabel().font(.system(size: 10 * scale)) } }
            .frame(height: (CGFloat(max(1, categories.count)) * 30 + 30) * scale)

            Table(categories) {
                TableColumn("类型") { Text($0.category.displayName) }
                TableColumn("文件数") { Text("\($0.count)").monospacedDigit() }
                TableColumn("占用") { Text(ByteSize.format($0.bytes)).monospacedDigit() }
            }
        }
    }
}
