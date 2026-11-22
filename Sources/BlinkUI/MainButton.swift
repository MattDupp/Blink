import SwiftUI

/// The main button of a window: the one Return presses, which macOS draws in the accent
/// colour.
///
/// In the app this is `.keyboardShortcut(.defaultAction)` and nothing more. The pictures
/// are another matter: they are rendered in a window that is never shown (`ScreenRenderer`),
/// and macOS tints the main button only in the window in front. Every picture in the
/// README showed a grey "Continue", so a reader could not tell which button the page
/// leads to. In a picture the button is therefore drawn by hand, tinted as the app shows it.
public extension View {
    func mainButton() -> some View { modifier(MainButton()) }
}

private struct MainButton: ViewModifier {
    @Environment(\.isPicture) private var isPicture

    func body(content: Content) -> some View {
        if isPicture {
            content.buttonStyle(PictureMainButtonStyle())
        } else {
            content.keyboardShortcut(.defaultAction)
        }
    }
}

/// The system's main button, drawn: the sizes are those of a bordered button on macOS.
/// Greyed, it is drawn like any greyed button, as in the app.
private struct PictureMainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large, small = controlSize == .small || controlSize == .mini
        configuration.label
            .textStyle(small ? .subheadline : .body)
            .foregroundStyle(isEnabled ? Color.white : Color.primary.opacity(0.3))
            .padding(.horizontal, large ? 13 : small ? 7 : 10)
            .frame(height: large ? 28 : small ? 19 : 22)
            .background(isEnabled ? Color.accentColor : Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: large ? 7 : 5.5))
    }
}

private struct IsPictureKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// The view is being rendered to a picture, not shown in a window (`ScreenRenderer`).
    var isPicture: Bool {
        get { self[IsPictureKey.self] }
        set { self[IsPictureKey.self] = newValue }
    }
}
