import SwiftUI

/// Shown once, at the first launch of an app that already HAS a model (one built in by
/// `make monitor`), BEFORE the camera is asked for. An app with no model opens its setup
/// instead, whose first page says the same and more (`SetupView`).
///
/// An app that turns the camera on needs to say why first: what it looks at, where the
/// pictures go (nowhere), and how to switch it off. Then the permission question that
/// follows is one the user is expecting.
struct WelcomeView: View {
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "eye")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 60, height: 60)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blink Monitor")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Counts your blinks, and tells you when you forget to.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                WelcomePoint(symbol: "camera", title: "It watches your eyes through the camera",
                      text: "A small model, trained on your own eyes, reads each eye 30 times a second and counts the moments they close.")
                WelcomePoint(symbol: "lock.shield", title: "Nothing leaves this Mac",
                      text: "While it counts, pictures are read and thrown away at once, and only numbers are kept: blinks for each minute, in a file you can open. Setup keeps small pictures of your eyes, on this Mac only.")
                WelcomePoint(symbol: "light.beacon.max", title: "The green camera light stays on",
                      text: "That is macOS telling you the camera is in use. Pause, in the menu-bar panel, turns the camera off for real; so does closing the lid or locking the screen.")
                WelcomePoint(symbol: "bell", title: "A reminder when your blink rate is low",
                      text: "People blink far less at a screen. When your rate stays low for 3 minutes you get a notification. Left unanswered, it comes less and less often: after 5, 15, 30, then 60 minutes.")
            }

            // An app with no window and no Dock icon has to say where it went.
            HStack(spacing: 14) {
                MenuBarSketch()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Afterwards, look up").fontWeight(.semibold)
                    Text("Blink Monitor has no window and no Dock icon. It lives in the menu bar, at the top right of the screen: click the eye. To watch it work, open Live View from there.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Text("Next, macOS will ask for the camera, then for notifications.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}

/// A drawing of the menu bar's right end, with the app's item marked.
struct MenuBarSketch: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            HStack(spacing: 3) {
                Image(systemName: "eye")
                Text("13").monospacedDigit()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 1.5))
            Text("16:42").monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// One thing to know, with its symbol: the welcome and setup windows list a few.
struct WelcomePoint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
