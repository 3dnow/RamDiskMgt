import Foundation

public enum ByteSize {
    public static let kib: UInt64 = 1024
    public static let mib: UInt64 = 1024 * 1024
    public static let gib: UInt64 = 1024 * 1024 * 1024

    /// 解析 "512"、"512M"、"1.5G"、"2gb"、"100MiB"、"4096K"。不带单位按 MB 处理。
    public static func parse(_ text: String) -> UInt64? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        let numberPart = s.prefix { "0123456789.".contains($0) }
        guard let value = Double(numberPart), value > 0 else { return nil }
        var unit = String(s.dropFirst(numberPart.count)).trimmingCharacters(in: .whitespaces)
        for suffix in ["ib", "b"] where unit.hasSuffix(suffix) && unit.count > suffix.count {
            unit.removeLast(suffix.count)
            break
        }
        let multiplier: UInt64
        switch unit {
        case "", "m": multiplier = mib
        case "k": multiplier = kib
        case "g": multiplier = gib
        case "t": multiplier = gib * 1024
        case "b", "byte", "bytes": multiplier = 1
        default: return nil
        }
        let bytes = value * Double(multiplier)
        guard bytes < Double(UInt64.max) else { return nil }
        return UInt64(bytes.rounded())
    }

    /// 以 1024 为底的人类可读格式，例如 "1.5 GB"、"512 MB"。
    public static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        // 1023.96 MB 这类值四舍五入后是 1024，进位到下一个单位。
        if value >= 1023.5, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return "\(text) \(units[index])"
    }

    public static func format(_ bytes: Int64) -> String {
        bytes < 0 ? "-" + format(UInt64(-bytes)) : format(UInt64(bytes))
    }

    /// 向上取整到 `alignment` 的倍数。
    public static func align(_ bytes: UInt64, to alignment: UInt64) -> UInt64 {
        guard alignment > 0 else { return bytes }
        return (bytes + alignment - 1) / alignment * alignment
    }
}
