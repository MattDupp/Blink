import SwiftUI
import BlinkUI

/// The root of every window: its words are larger when the user asked for that in
/// Settings, and change the moment the switch does.
struct AppText<Content: View>: View {
    @ObservedObject var preferences: Preferences
    @ViewBuilder let content: Content

    var body: some View {
        content.textScale(larger: preferences.largerText)
    }
}
