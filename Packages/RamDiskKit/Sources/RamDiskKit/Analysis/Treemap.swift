import CoreGraphics

/// Squarified treemap（Bruls, Huizing, van Wijk 2000）：让矩形尽量接近正方形。
public enum Treemap {
    public struct Cell<ID: Hashable>: Hashable {
        public let id: ID
        public let rect: CGRect
    }

    /// - Parameters:
    ///   - items: (标识, 权重)，权重 ≤ 0 的条目会被忽略。
    ///   - rect: 布局区域。
    public static func layout<ID: Hashable>(_ items: [(id: ID, value: Double)], in rect: CGRect) -> [Cell<ID>] {
        let positive = items.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard !positive.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let total = positive.reduce(0) { $0 + $1.value }
        let scale = Double(rect.width * rect.height) / total
        let areas = positive.map { (id: $0.id, area: $0.value * scale) }

        var cells: [Cell<ID>] = []
        var remaining = rect
        var row: [(id: ID, area: Double)] = []
        var index = 0

        while index < areas.count {
            let item = areas[index]
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [item], side: side) <= worst(row, side: side) {
                row.append(item)
                index += 1
            } else {
                remaining = place(row, in: remaining, into: &cells)
                row = []
            }
        }
        if !row.isEmpty { _ = place(row, in: remaining, into: &cells) }
        return cells
    }

    /// 行内最差的长宽比。
    static func worst<ID>(_ row: [(id: ID, area: Double)], side: Double) -> Double {
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, side > 0 else { return .infinity }
        let maxArea = row.map(\.area).max() ?? 0
        let minArea = row.map(\.area).min() ?? 0
        let s2 = side * side
        return max(s2 * maxArea / (sum * sum), (sum * sum) / (s2 * minArea))
    }

    /// 沿较短边摆放一行，返回剩余区域。
    static func place<ID>(_ row: [(id: ID, area: Double)], in rect: CGRect, into cells: inout [Cell<ID>]) -> CGRect {
        let sum = row.reduce(0) { $0 + $1.area }
        if rect.width >= rect.height {
            // 竖着摆一列
            let width = CGFloat(sum / Double(rect.height))
            var y = rect.minY
            for item in row {
                let h = CGFloat(item.area / Double(width))
                cells.append(Cell(id: item.id, rect: CGRect(x: rect.minX, y: y, width: width, height: h)))
                y += h
            }
            return CGRect(x: rect.minX + width, y: rect.minY, width: max(0, rect.width - width), height: rect.height)
        } else {
            let height = CGFloat(sum / Double(rect.width))
            var x = rect.minX
            for item in row {
                let w = CGFloat(item.area / Double(height))
                cells.append(Cell(id: item.id, rect: CGRect(x: x, y: rect.minY, width: w, height: height)))
                x += w
            }
            return CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: max(0, rect.height - height))
        }
    }
}
