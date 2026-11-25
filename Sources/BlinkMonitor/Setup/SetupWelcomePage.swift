import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The setup's first page: what it is, why, and how long it takes.

struct WelcomePage: View {
    @ObservedObject var model: SetupModel
    let actions: SetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "eye")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 60, height: 60)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blink")
                        .textStyle(.largeTitle, weight: .bold, design: .rounded)
                    Text(AppWords.tagline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                WelcomePoint(symbol: "camera", title: "It watches your eyes through the camera",
                             text: "A small model, which is a program that has learned what your open and closed eyes look like, reads each eye 30 times a second and counts the moments they close.")
                WelcomePoint(symbol: "graduationcap", title: "First it learns your eyes",
                             text: "Eyes, glasses and lamps differ, so the model is trained on yours, on this Mac. You record your eyes twice, two minutes each, and it learns from the pictures.")
                WelcomePoint(symbol: "lock.shield", title: "Nothing leaves this Mac",
                             text: "The recordings are small pictures of your eyes, never your face. They stay in a folder only your account can read, and Settings deletes them. The app makes no network connection.")
                WelcomePoint(symbol: "light.beacon.max", title: "The green camera light stays on",
                             text: "That is macOS telling you the camera is in use. Pause, in the menu-bar panel, turns the camera off for real.")
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionTitle("The next eight minutes")
                TimelineRow(number: 1, title: "Check the camera", time: model.isDemo ? "a moment" : "half a minute")
                TimelineRow(number: 2, title: "Record your eyes, twice",
                            time: model.isDemo ? "a few seconds each, in silence" : "two minutes each, a voice guides you")
                TimelineRow(number: 3, title: "Train your model", time: "under a minute")
                TimelineRow(number: 4, title: "Test it: you blink, it counts", time: "fifteen seconds")
                Text(model.isDemo
                     ? "In the demo the eyes are painted and blink by themselves: you only press the buttons."
                     : "You need sound: the voice guides you while your eyes are closed, for half of each recording. You can stop at any step and come back later: what is recorded stays.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Text(model.isDemo ? "The demo does not use the camera." : "Next, macOS will ask for the camera.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let tryDemo = actions.tryDemo {
                    Button("Try the Demo First") { tryDemo() }
                        .controlSize(.large)
                        .help("The whole app on made-up eyes: no camera, nothing recorded")
                }
                Button(model.isDemo ? "See the Setup" : "Set Up on My Eyes") { model.begin() }
                    .mainButton()
                    .controlSize(.large)
            }
        }
    }
}

private struct TimelineRow: View {
    let number: Int
    let title: String
    let time: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.08), in: Circle())
            Text(title)
            Spacer(minLength: 12)
            Text(time)
                .textStyle(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Camera
