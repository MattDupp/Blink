import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

/// What the setup window's buttons do outside of it.
struct SetupActions {
    /// "Try the demo first". Nil where it is not offered (the demo itself).
    var tryDemo: (() -> Void)?
    /// "Set Up on My Eyes", at the end of the demo. Nil where the demo cannot be left
    /// (the demo app itself, which is another app).
    var leaveDemo: (() -> Void)?
    var openCameraSettings: () -> Void = {}
    var showFiles: () -> Void = {}
    var close: () -> Void = {}
    /// "Done", on the last page: closes the window and shows where the app lives.
    var done: () -> Void = {}
    /// "Watch It Count", on the last page: closes the window and opens Live View.
    var watchItCount: () -> Void = {}
    var openSettings: () -> Void = {}
    /// System Settings, on the page of this app's notifications.
    var openNotificationSettings: () -> Void = {}
}

/// The setup window: one page per step, and above them where you are.
///
/// Every page answers the same three questions before it asks for anything: what is
/// happening, how long it takes, and why it is needed.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    /// Shown in place of the camera picture (the screenshots have none).
    var cameraNote: String?
    let actions: SetupActions

    var body: some View {
        VStack(spacing: 0) {
            if model.isDemo { DemoStrip() }
            if model.welcomeBack != nil {
                WelcomeBackPage(model: model, actions: actions)
                    .padding(26)
            } else {
            if model.step != .welcome && model.step != .done {
                StepsBar(step: model.step)
                    .padding(.horizontal, 26)
                    .padding(.top, 18)
            }
            Group {
                switch model.step {
                case .welcome: WelcomePage(model: model, actions: actions)
                case .camera: CameraPage(model: model, cameraNote: cameraNote, actions: actions)
                case .record: RecordPage(model: model, cameraNote: cameraNote, actions: actions)
                case .train: TrainPage(model: model)
                case .proof: ProofPage(model: model, actions: actions)
                case .done: DonePage(model: model, actions: actions)
                }
            }
            .padding(26)
            }
        }
        .windowWidth(700)
        // The end of a closed-eye pose, for someone who cannot hear its sound: the whole
        // window changes its brightness, once (`PoseSignal`). Light passes closed eyelids.
        .overlay { PoseGlow(amount: model.glow) }
    }
}

/// White over a dark window, black over a light one (`PoseSignal.change`).
private struct PoseGlow: View {
    let amount: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (PoseSignal.change(windowIsDark: colorScheme == .dark) == .brighter ? Color.white : Color.black)
            .opacity(amount)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Shown when the app itself reopens a setup left unfinished: what is done, what is
/// next, and the camera only on Continue.
private struct WelcomeBackPage: View {
    @ObservedObject var model: SetupModel
    let actions: SetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle("Welcome back", "The setup is not finished yet, so nothing is counted.")
            VStack(alignment: .leading, spacing: 14) {
                WelcomePoint(symbol: "checkmark.circle", title: "What is done", text: done)
                WelcomePoint(symbol: "arrow.right.circle", title: "What is next", text: next)
                WelcomePoint(symbol: "light.beacon.max", title: "The camera is off",
                             text: "It turns on when you press Continue, and its green light with it.")
            }
            HStack {
                Spacer()
                Button("Not Now") { actions.close() }
                    .controlSize(.large)
                    .help("Closes this window. Continue Setup is in the menu-bar panel.")
                Button("Continue") { model.continueSetup() }
                    .mainButton()
                    .controlSize(.large)
            }
        }
    }

    private var done: String {
        if model.info != nil { return "Your eyes are recorded and your model is trained." }
        let count = model.sessions.count
        return count == 0 ? "Nothing is recorded yet." : "\(Format.count(count, "recording")) of \(model.targetSessions) saved. Nothing was lost."
    }

    private var next: String {
        if model.info != nil { return "The test: you blink \(Format.word(ProofTest.ticks)) times and it counts. About \(Format.count(Int((ProofTest.secondsBeforeFirstTick + Double(ProofTest.ticks) * ProofTest.secondsBetweenTicks).rounded()), "second"))." }
        let left = max(1, model.targetSessions - model.sessions.count)
        return "A look at the camera, then \(Format.count(left, "recording")) of two minutes, the training and the test. About \(left * 3 + 1) minutes."
    }
}

/// Said on every page for as long as the setup runs on painted eyes.
private struct DemoStrip: View {
    var body: some View {
        Label("Demo: these eyes are painted, and the camera is off. The recording, the training and the test are real.",
              systemImage: "sparkles")
            .textStyle(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 26)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.16))
    }
}

// MARK: - Where you are

private struct StepsBar: View {
    let step: SetupModel.Step

    private static let steps: [(SetupModel.Step, String)] = [
        (.camera, "Camera"), (.record, "Record"), (.train, "Train"), (.proof, "Test"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Rectangle()
                        .fill(entry.0 <= step ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12))
                        .frame(height: 2)
                }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(entry.0 < step ? Color.doneGreen : (entry.0 == step ? Color.accentColor : Color.primary.opacity(0.1)))
                        if entry.0 < step {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(entry.0 == step ? Color.white : Color.secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(entry.1)
                        .textStyle(.callout, weight: entry.0 == step ? .semibold : .regular)
                        .foregroundStyle(entry.0 == step ? Color.primary : Color.secondary)
                }
                .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(Self.steps.firstIndex { $0.0 == step }.map { $0 + 1 } ?? 1) of \(Self.steps.count)")
    }
}

// MARK: - Welcome
