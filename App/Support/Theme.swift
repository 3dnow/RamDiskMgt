import AppKit
import RamDiskKit
import SwiftUI

/// 图表配色：dataviz 参考色板的 8 个分类槽位，按固定顺序分配给文件类别；“其他”“系统文件”用中性灰。
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static func color(for category: FileCategory) -> Color {
        switch category {
        case .video: return dynamic(light: 0x2a78d6, dark: 0x3987e5)        // 1 blue
        case .image: return dynamic(light: 0xeb6834, dark: 0xd95926)        // 2 orange
        case .audio: return dynamic(light: 0x1baf7a, dark: 0x199e70)        // 3 aqua
        case .archive: return dynamic(light: 0xeda100, dark: 0xc98500)      // 4 yellow
        case .diskImage: return dynamic(light: 0xe87ba4, dark: 0xd55181)    // 5 magenta
        case .document: return dynamic(light: 0x008300, dark: 0x008300)     // 6 green
        case .code: return dynamic(light: 0x4a3aa7, dark: 0x9085e9)         // 7 violet
        case .application: return dynamic(light: 0xe34948, dark: 0xe66767)  // 8 red
        case .other: return dynamic(light: 0x898781, dark: 0x6b6a65)
        case .system: return dynamic(light: 0xc3c2b7, dark: 0x45443f)
        }
    }

    /// 色块上的文字：深色填充用白字，浅色填充用黑字。
    static func labelColor(for category: FileCategory) -> Color {
        switch category {
        case .archive, .system, .diskImage, .audio: return dynamic(light: 0x0b0b0b, dark: 0xffffff)
        default: return .white
        }
    }

    static let directoryFill = dynamic(light: 0xe1e0d9, dark: 0x2c2c2a)
    static let surface = dynamic(light: 0xfcfcfb, dark: 0x1a1a19)

    // 状态色（只与图标 + 文字一起使用）
    static let good = Color(nsColor: NSColor(hex: 0x0ca30c))
    static let warning = Color(nsColor: NSColor(hex: 0xfab219))
    static let critical = Color(nsColor: NSColor(hex: 0xd03b3b))

    static func usageColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: return .accentColor
        case ..<0.9: return warning
        default: return critical
        }
    }

    static func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return good
        case .warning: return warning
        case .critical: return critical
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension RamDiskBackend {
    var symbol: String {
        switch self {
        case .apfs, .apfsCaseSensitive: return "memorychip"
        case .hfsPlus: return "externaldrive"
        case .tmpfs: return "bolt.horizontal"
        }
    }
}

extension Date {
    var shortRelative: String {
        if abs(timeIntervalSinceNow) < 10 { return "刚刚" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }

    var shortStamp: String {
        formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute())
    }
}

/// 用量条：已用部分随阈值变色，旁边配文字，颜色不单独承载含义。
struct UsageBar: View {
    @Environment(\.fontScale) private var scale
    var fraction: Double
    var height: CGFloat = 8

    var body: some View {
        let height = self.height * scale
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Theme.usageColor(fraction))
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .accessibilityLabel("已用 \(Int(fraction * 100))%")
    }
}
