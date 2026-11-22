import SwiftUI

/// "Larger text": the one place that decides how large the app's words are drawn.
///
/// macOS has no Dynamic Type: a text style such as `.callout` is 12 points whatever the
/// environment says (measured on 22 November 2026: `.dynamicTypeSize(.accessibility3)`
/// changes nothing on a Mac). So the app scales its own text. Every view asks for a style
/// through `textStyle(_:)` instead of `font(_:)`, and a window's root says once whether
/// the text is larger (`textScale(larger:)`).
///
/// With the switch off nothing differs from before: `textStyle(.callout)` IS
/// `font(.callout)`. With it on, each style is drawn `larger` times its size, the words
/// that name no style (the body text, the labels of switches) follow, controls take
/// macOS's large size, and a window is a little wider so that sentences keep their lines.
///
/// What does not scale, on purpose: the big numbers (already 34 points and more), the
/// symbols, and the labels drawn inside the charts, whose room is fixed.
public enum TextScale {

    /// How much larger "Larger text" is.
    public static let larger: CGFloat = 1.2
    /// How much wider a window gets with it: less than the text, or the History window
    /// would not fit a 13-inch screen.
    public static let widerWindow: CGFloat = 1.12

    /// The size macOS gives each text style, in points (measured against
    /// `Font.system(size:)` on macOS 15: the two draw at the same size).
    public static func points(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        @unknown default: return 13
        }
    }

    /// The weight a style has when none is asked for.
    static func weight(_ style: Font.TextStyle) -> Font.Weight {
        switch style {
        case .headline: return .bold
        case .caption2: return .medium
        default: return .regular
        }
    }

    /// The font of a style at a scale. At 1 it is the system's own, untouched.
    public static func font(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil,
                            scale: CGFloat) -> Font {
        guard scale != 1 else {
            let font = design.map { Font.system(style, design: $0) } ?? Font.system(style)
            return weight.map { font.weight($0) } ?? font
        }
        return .system(size: (points(style) * scale).rounded(), weight: weight ?? self.weight(style), design: design ?? .default)
    }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

public extension EnvironmentValues {
    /// 1, or `TextScale.larger` under a root that asked for larger text.
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

private struct StyledText: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        content.font(TextScale.font(style, weight: weight, design: design, scale: scale))
    }
}

private struct SmallControl: ViewModifier {
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        content.controlSize(scale > 1 ? .regular : .small)
    }
}

private struct WindowWidth: ViewModifier {
    @Environment(\.textScale) private var scale
    let width: CGFloat
    let height: CGFloat?
    let alignment: Alignment

    func body(content: Content) -> some View {
        let wider = scale > 1 ? TextScale.widerWindow : 1
        content.frame(width: (width * wider).rounded(), height: height.map { ($0 * wider).rounded() }, alignment: alignment)
    }
}

public extension View {
    /// The font of a text style, larger when the window asked for larger text. Use it
    /// wherever `font(_:)` would name a style.
    func textStyle(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(StyledText(style: style, weight: weight, design: design))
    }

    /// A small control, which larger text makes a regular one.
    func smallControl() -> some View {
        modifier(SmallControl())
    }

    /// The fixed width of a window's content (and its height, where it has one), a
    /// little wider with larger text.
    func windowWidth(_ width: CGFloat, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(WindowWidth(width: width, height: height, alignment: alignment))
    }

    /// At the root of a window: whether its text is larger. It sets the scale the styles
    /// read, the font of the words that name no style, and the size of the controls.
    func textScale(larger: Bool) -> some View {
        environment(\.textScale, larger ? TextScale.larger : 1)
            .font(larger ? Font.system(size: (TextScale.points(.body) * TextScale.larger).rounded()) : nil)
            .controlSize(larger ? .large : .regular)
    }
}
