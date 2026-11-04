import SwiftUI

/// 全局字号缩放。macOS 上 SwiftUI 的 dynamicTypeSize 对文字样式不起作用（实测 caption 在 xSmall 与 xxxLarge 下尺寸相同），
/// 所以按 macOS 各文字样式的磅值自行缩放。
enum FontScale {
    static let storageKey = "fontScale"
    static let defaultValue: Double = 1.3
    static let presets: [(name: String, value: Double)] = [("标准", 1.0), ("较大", 1.15), ("大", 1.3), ("特大", 1.5), ("超大", 1.75)]
    static let range: ClosedRange<Double> = 0.9...2.0

    static func stepped(_ value: Double, by delta: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, ((value + delta) * 20).rounded() / 20))
    }
}

/// macOS 文字样式的基准磅值。
enum TextStyle {
    case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption, caption2

    var baseSize: CGFloat {
        switch self {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11.5
        case .footnote, .caption: return 11
        case .caption2: return 10.5
        }
    }

    var defaultWeight: Font.Weight { self == .headline ? .semibold : .regular }
}

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var fontScale: CGFloat {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.fontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight))
    }
}

private struct ScaledFrameModifier: ViewModifier {
    @Environment(\.fontScale) private var scale
    var width: CGFloat?
    var height: CGFloat?
    var minWidth: CGFloat?
    var idealWidth: CGFloat?
    var maxWidth: CGFloat?
    var minHeight: CGFloat?
    var maxHeight: CGFloat?
    var alignment: Alignment = .center

    func body(content: Content) -> some View {
        let s = { (v: CGFloat?) in v.map { $0 * scale } }
        if width != nil || height != nil {
            content.frame(width: s(width), height: s(height), alignment: alignment)
        } else {
            content.frame(minWidth: s(minWidth), idealWidth: s(idealWidth), maxWidth: s(maxWidth),
                          minHeight: s(minHeight), maxHeight: s(maxHeight), alignment: alignment)
        }
    }
}

extension View {
    /// 按全局缩放设置字号。
    func appFont(_ style: TextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(AppFontModifier(size: style.baseSize, weight: weight ?? style.defaultWeight))
    }

    func appFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(AppFontModifier(size: size, weight: weight))
    }

    /// 尺寸随字号缩放的 frame。
    func scaledFrame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(ScaledFrameModifier(width: width, height: height, alignment: alignment))
    }

    func scaledFrame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                     minHeight: CGFloat? = nil, maxHeight: CGFloat? = nil) -> some View {
        modifier(ScaledFrameModifier(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
                                     minHeight: minHeight, maxHeight: maxHeight))
    }

    /// 根视图使用：注入缩放比例、默认正文字号和控件尺寸。
    func appTextScale() -> some View {
        modifier(AppTextScaleModifier())
    }
}

private struct AppTextScaleModifier: ViewModifier {
    @AppStorage(FontScale.storageKey) private var stored = FontScale.defaultValue

    func body(content: Content) -> some View {
        let scale = CGFloat(DebugSnapshot.fontScaleOverride ?? stored)
        content
            .buttonStyle(ScaledButtonStyle(base: .automatic))
            .environment(\.fontScale, scale)
            .font(.system(size: TextStyle.body.baseSize * scale))
            .controlSize(scale >= 1.2 ? .large : .regular)
    }
}

/// 菜单命令：放大 / 缩小 / 实际大小。
struct FontScaleCommands: Commands {
    @AppStorage(FontScale.storageKey) private var scale = FontScale.defaultValue

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("放大字体") { scale = FontScale.stepped(scale, by: 0.1) }
                .keyboardShortcut("+")
            Button("缩小字体") { scale = FontScale.stepped(scale, by: -0.1) }
                .keyboardShortcut("-")
            Button("默认字体大小") { scale = FontScale.defaultValue }
                .keyboardShortcut("0")
        }
    }
}

// MARK: - 控件

/// 原生按钮不继承环境字体（实测），只认 label 上直接设置的字体。
/// 这个样式把缩放后的字号直接加到 label 上，再交给原本的按钮样式渲染。
struct ScaledButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    @Environment(\.fontScale) private var scale
    let base: Base
    var size: CGFloat = TextStyle.body.baseSize

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.font(.system(size: size * scale))
        }
        .buttonStyle(base)
    }
}

extension View {
    /// 替代 `.buttonStyle(...)`，让按钮文字随全局字号缩放。
    func scaledButtonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
        buttonStyle(ScaledButtonStyle(base: style))
    }
}

/// 原生分段控件的文字无法放大（实测），用按钮自绘一个外观相近的分段选择器。
struct SegmentedTabs<Value: Hashable>: View {
    @Environment(\.fontScale) private var scale
    @Binding var selection: Value
    let items: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Text(item.title)
                        .font(.system(size: TextStyle.body.baseSize * scale, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 14 * scale)
                        .padding(.vertical, 4 * scale)
                        .frame(maxWidth: .infinity)
                        .background(selected ? Color(nsColor: .controlColor) : .clear, in: RoundedRectangle(cornerRadius: 6 * scale))
                        .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2 * scale)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8 * scale))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 空状态提示。系统 ContentUnavailableView 的字体固定、不随缩放，所以自己画。
struct EmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .appFont(size: 40, weight: .light)
                .foregroundStyle(.secondary)
            Text(title).appFont(.title2, weight: .semibold)
            if let message {
                Text(message)
                    .appFont(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .scaledFrame(maxWidth: 520)
            }
            actions().padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, symbol: String, message: String? = nil) {
        self.init(title: title, symbol: symbol, message: message, actions: { EmptyView() })
    }
}
