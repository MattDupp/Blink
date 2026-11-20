import SwiftUI

/// Shown once, at the first launch, BEFORE the camera is asked for.
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
                Point(symbol: "camera", title: "It watches your eyes through the camera",
                      text: "A small model, trained on your own eyes, reads each eye 30 times a second and counts the moments they close.")
                Point(symbol: "lock.shield", title: "Nothing leaves this Mac",
                      text: "Pictures are analysed and thrown away at once. Only numbers are kept: blinks per minute, in a file you can open.")
                Point(symbol: "light.beacon.max", title: "The green camera light stays on",
                      text: "That is macOS telling you the camera is in use. Pause, in the menu, turns the camera off for real; so does closing the lid or locking the screen.")
                Point(symbol: "bell", title: "A nudge when you blink too little",
                      text: "People blink far less at a screen. When your rate stays low for a few minutes you get one notification, never more than one every five minutes.")
            }

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

private struct Point: View {
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
