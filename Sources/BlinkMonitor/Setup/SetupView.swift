import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

/// What the setup window's buttons do outside of it.
struct SetupActions {
    /// "Try the demo first". Nil where it is not offered (the demo itself).
    var tryDemo: (() -> Void)?
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

/// What a failed training is called, in a sentence for a person. The trainer's own
/// words (a signal number, an assertion) go to the log and to "Copy the Details".
enum TrainingFailureWords {
    static func plain(_ reason: String) -> String {
        if reason.hasPrefix("The training program stopped before the end") { return "The training program stopped unexpectedly." }
        if reason.hasPrefix("The training program stopped answering") { return "The training stopped making progress, and was ended." }
        if reason.hasPrefix("The training program could not be started") { return "The training program could not be started." }
        if reason.hasPrefix("The model's folder could not be prepared") || reason.hasPrefix("The trained model could not be put in place") {
            return "The model could not be written to disk."
        }
        // What the training said itself is already a sentence (too few pictures, a check
        // that failed): its first line.
        return reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? "The training stopped."
    }

    static let advice = "Quit apps that work the graphics processor hard (games, video editing), or restart the Mac, then try again."
    /// Where a problem is reported. The browser opens it: the app itself connects to nothing.
    static let reportPage = URL(string: "https://github.com/MattDupp/blink-monitor/issues/new")
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
                case .proof: ProofPage(model: model)
                case .done: DonePage(model: model, actions: actions)
                }
            }
            .padding(26)
        }
        .frame(width: 700)
    }
}

/// Said on every page for as long as the setup runs on painted eyes.
private struct DemoStrip: View {
    var body: some View {
        Label("Demo: these eyes are painted, and the camera is off. The recording, the training and the test are real.",
              systemImage: "sparkles")
            .font(.callout)
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
                        Circle().fill(entry.0 < step ? Color.green : (entry.0 == step ? Color.accentColor : Color.primary.opacity(0.1)))
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
                        .font(.callout.weight(entry.0 == step ? .semibold : .regular))
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

private struct WelcomePage: View {
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
                    Text("Blink Monitor")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Counts your blinks, and tells you when you forget to.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                WelcomePoint(symbol: "camera", title: "It watches your eyes through the camera",
                             text: "A small model reads each eye 30 times a second and counts the moments they close.")
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Text(model.isDemo ? "The demo does not use the camera." : "Next, macOS will ask for the camera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let tryDemo = actions.tryDemo {
                    Button("Try the Demo First") { tryDemo() }
                        .controlSize(.large)
                        .help("The whole app on made-up eyes: no camera, nothing recorded")
                }
                Button(model.isDemo ? "See the Setup" : "Set Up on My Eyes") { model.begin() }
                    .keyboardShortcut(.defaultAction)
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
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Camera

private struct CameraPage: View {
    @ObservedObject var model: SetupModel
    let cameraNote: String?
    let actions: SetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle("Check the camera",
                      "Sit as you usually do at the screen. The two green squares should sit on your eyes.")
            if let trouble = CameraTrouble(model.camera) {
                CameraTroubleCard(trouble: trouble, model: model, actions: actions)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        SetupCamera(model: model, note: cameraNote)
                        EyePair(model: model)
                    }
                    .frame(width: SetupCamera.width)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(checks, id: \.title) { CheckRow(check: $0) }
                    }
                }
            }
            HStack {
                Text("Why: a recording of an empty chair, or of eyes too small to read, teaches the model nothing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Continue") { model.cameraLooksRight() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!model.canLeaveCameraCheck)
            }
        }
    }

    private var checks: [Check] {
        let watching = model.camera == .on
        var checks: [Check] = []
        if watching && model.cameraSilent {
            checks.append(Check(state: .warning, title: "The camera is not sending pictures",
                                detail: "With the lid closed that is expected. Open it: the Mac's own camera has to face you."))
        } else if model.faceInView {
            checks.append(Check(state: .good, title: "Your face is in view", detail: "Stay where you are comfortable: that is where it will watch you."))
        } else if watching && model.faceMissing {
            checks.append(Check(state: .warning, title: "No face found",
                                detail: "The Mac's own camera has to face you: the lid open, you in front of it."))
        } else {
            checks.append(Check(state: .waiting, title: "Looking for your face", detail: "It takes a second or two."))
        }

        if !model.faceInView {
            checks.append(Check(state: .waiting, title: "Size of your eyes in the picture", detail: ""))
            checks.append(Check(state: .waiting, title: "Light on your face", detail: ""))
        } else {
            checks.append(model.eyesLargeEnough
                ? Check(state: .good, title: "Your eyes are large enough",
                        detail: "")
                : Check(state: .warning, title: "You are far from the camera",
                        detail: "Come closer to the camera if you can."))
            checks.append(model.lightEnough
                ? Check(state: .good, title: "There is enough light", detail: "Your second recording will ask for another light.")
                : Check(state: .warning, title: "It is dark",
                        detail: "A dark picture is noisy, and the model learns less from it. More light on your face helps. You can go on as you are."))
        }
        return checks
    }
}

private struct Check {
    enum State { case waiting, good, warning }
    let state: State
    let title: String
    let detail: String
}

private struct CheckRow: View {
    let check: Check

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch check.state {
                case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
                case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 17))
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(check.state == .waiting ? Color.secondary : Color.primary)
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What can keep the camera from giving pictures, worded for the window.
private struct CameraTrouble {
    let title: String
    let text: String
    let refused: Bool

    init?(_ state: SetupModel.CameraState) {
        switch state {
        case .refused:
            title = "Blink Monitor is not allowed to use the camera"
            text = "Allow it in System Settings > Privacy & Security > Camera. macOS may then ask to quit and reopen "
                + "Blink Monitor: say yes, the setup goes on from this page."
            refused = true
        case .failed(let reason):
            title = "The camera could not be started"
            text = reason
            refused = false
        case .off, .asking, .on:
            return nil
        }
    }
}

private struct CameraTroubleCard: View {
    let trouble: CameraTrouble
    @ObservedObject var model: SetupModel
    let actions: SetupActions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 8) {
                Text(trouble.title).font(.headline)
                Text(trouble.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if trouble.refused {
                        Button("Open Camera Settings") { actions.openCameraSettings() }
                    }
                    Button("Check Again") { model.askForCameraAgain() }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The camera picture with the eye squares, as the setup shows it.
private struct SetupCamera: View {
    @ObservedObject var model: SetupModel
    let note: String?

    static let width: CGFloat = 392

    var body: some View {
        // A stated size: without a picture, the view would take the size of its sentence.
        CameraPreviewView(image: model.preview, frameSize: model.frameSize, eyeRects: model.eyeRects, placeholder: placeholder)
            .frame(width: Self.width, height: Self.width * 9 / 16)
    }

    private var placeholder: String {
        if let note { return note }
        if model.isDemo { return "Demo: there is no camera picture. The eyes on the right are painted." }
        switch model.camera {
        case .asking: return "macOS is asking for the camera…"
        case .refused: return "Camera access was refused."
        case .failed(let reason): return reason
        case .off, .on: return model.cameraSilent ? "The camera is not sending pictures." : "Starting the camera…"
        }
    }
}

/// The two 64x64 pictures cut from the frame: what is recorded, and what the model reads.
private struct EyePair: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            EyeThumbnail(image: model.leftCrop)
            EyeThumbnail(image: model.rightCrop)
            VStack(alignment: .leading, spacing: 2) {
                Text("What the model sees")
                    .font(.callout.weight(.semibold))
                Text("Two small pictures, \(EyeCropper.outputSize) pixels across. Nothing else of the camera picture is ever saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct EyeThumbnail: View {
    let image: CGImage?
    var side: CGFloat = 64

    var body: some View {
        ZStack {
            Color.black
            if let image {
                // No smoothing: you see the real 64x64 pixels, as the model gets them.
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}

// MARK: - Record

private struct RecordPage: View {
    @ObservedObject var model: SetupModel
    let cameraNote: String?
    let actions: SetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let trouble = CameraTrouble(model.camera) {
                PageTitle("Record your eyes", "The camera is needed for this step.")
                CameraTroubleCard(trouble: trouble, model: model, actions: actions)
            } else {
                SessionBanner(model: model)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        SetupCamera(model: model, note: cameraNote)
                        EyePair(model: model)
                    }
                    .frame(width: SetupCamera.width)
                    VStack(alignment: .leading, spacing: 12) {
                        SessionCounts(model: model)
                        if let problem = model.problem {
                            Text(problem)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle((model.faceFound && !model.soundMuted) || model.sessionRunning ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                buttons
            }
        }
    }

    private var footnote: String {
        if model.sessionRunning { return "Keep your face in front of the camera. Blink whenever you need to." }
        if model.camera == .on && !model.faceFound { return "No face in view: recording can start once the camera sees you." }
        if !model.parts.ownSessions {
            return "Recordings are saved in \(model.parts.sessionsRoot.path), the folder named when the app was started."
        }
        if model.soundMuted { return "The Mac's sound is off: you would not hear the voice that guides you. Turn it up, then press Play the Voice." }
        return "Sound on: the voice is your guide while your eyes are closed."
    }

    @ViewBuilder
    private var buttons: some View {
        if model.sessionRunning {
            // No Escape here: a stray key must not end two minutes of recording.
            Button("Stop") { model.stopSession() }
                .controlSize(.large)
                .help("Ends this recording. It is kept if most of it was done.")
        } else if model.enoughSessions {
            Button("Play the Voice") { model.playVoice() }
                .controlSize(.large)
            Button("Record Another") { model.startSession() }
                .controlSize(.large)
                .disabled(!model.canStartSession)
            Button("Train My Model") { model.train() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        } else {
            Button("Play the Voice") { model.playVoice() }
                .controlSize(.large)
                .help("Says one sentence, to check that you can hear the guide before you close your eyes.")
            Button("Start Recording \(model.nextSession)") { model.startSession() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.canStartSession)
        }
    }
}

/// The instruction of the moment, large: during a session it is what the voice says.
private struct SessionBanner: View {
    @ObservedObject var model: SetupModel

    private var phase: Phase { SessionScript.phases[min(model.phaseIndex, SessionScript.phases.count - 1)] }

    private var tint: Color {
        guard model.sessionRunning else { return model.sessionNote == nil ? .accentColor : .orange }
        return phase.label == .open ? .green : .indigo
    }

    private var stateText: String {
        switch model.phaseState {
        case .idle: return ""
        case .listening: return "Listen"
        case .settling: return "Get ready"
        case .recording: return "Recording"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.sessionRunning {
                HStack {
                    Text("Recording \(model.nextSession), pose \(model.phaseIndex + 1) of \(SessionScript.phases.count)")
                        .font(.headline)
                    Spacer()
                    if model.phaseState == .recording {
                        Circle().fill(Color.red).frame(width: 8, height: 8).accessibilityHidden(true)
                    }
                    Text(stateText)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(phase.instruction)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(tint).frame(width: geometry.size.width * model.recordProgress)
                    }
                }
                .frame(height: 6)
                // One dot per pose: where you are in the two minutes, at a glance.
                HStack(spacing: 5) {
                    ForEach(0..<SessionScript.phases.count, id: \.self) { index in
                        Circle()
                            .fill(index < model.phaseIndex ? Color.green : index == model.phaseIndex ? tint : Color.primary.opacity(0.15))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 4)
                .accessibilityHidden(true)
            } else {
                Text(guidance.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                if let note = model.sessionNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(guidance.lines, id: \.self) { line in
                    Text(line)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Between sessions: what a session is, what to change before the next, what comes after.
    private var guidance: (title: String, lines: [String]) {
        let recorded = model.sessions.count
        if model.sessionNote != nil {
            // The session that just ended was not kept: the note above says why.
            return ("Record again", [])
        }
        if model.enoughSessions {
            return ("\(recorded) recordings: enough to train",
                    ["One more recording in another light makes the model steadier. It takes two more minutes."])
        }
        if model.isDemo && recorded == 0 {
            return ("Recording 1 of \(model.targetSessions): painted eyes",
                    ["The real setup takes two minutes here, and a voice asks for \(SessionScript.phases.count) poses. The demo goes through them in seconds, in silence.",
                     "Why poses: every picture is saved with what you were asked to do. That is how the model gets the right answer."])
        }
        if recorded == 0 {
            return ("Recording 1 of \(model.targetSessions): record your eyes",
                    ["A voice asks for \(SessionScript.phases.count) poses, three seconds each: about two minutes.",
                     "Half of them are with your eyes closed. A sound ends each pose, so you know when to open them.",
                     "Why poses: every picture is saved with what you were asked to do. That is how the model gets the right answer."])
        }
        return ("Recording \(recorded) is saved. Change the light before recording \(recorded + 1)",
                ["Open or close the blinds, or switch a lamp on or off. Wear what you wear at the screen.",
                 "With glasses, check the picture: if a lamp or the screen shines on the lenses and hides your eyes, move the lamp or tilt the screen a little.",
                 "Why: one recording shows the model your eyes in one light. It has to work in all of yours."])
    }
}

private struct SessionCounts: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        let wanted = max(model.targetSessions, model.sessions.count)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Recordings")
            HStack(spacing: 6) {
                ForEach(0..<wanted, id: \.self) { index in
                    Circle()
                        .fill(index < model.sessions.count ? Color.green : Color.primary.opacity(0.15))
                        .frame(width: 10, height: 10)
                }
                Text("\(model.sessions.count) of \(wanted) recorded")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // One quiet line that moves, where two counters read like a data tool.
            let saved = model.sessions.reduce(0) { $0 + $1.pictures } + (model.sessionRunning ? model.sessionOpen + model.sessionClosed : 0)
            Text(saved > 0 ? "\(saved.formatted()) pictures saved so far, each with the pose it was taken in."
                           : "Ten pictures a second are saved during each pose, each with the pose it was taken in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Train

private struct TrainPage: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title, "It happens on this Mac, from your own pictures. Nothing is sent anywhere.")
            if case .failed(let reason, let attempts) = model.training {
                failure(reason: reason, attempts: attempts)
            } else {
                progress
                Samples(model: model)
                Text("What is happening: the model looks at every picture \(model.parts.passes) times. Each time the picture is altered: turned, shifted, darker, blurred. The eyelid is the only thing that stays the same, so that is what it learns to read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Spacer()
                if case .failed = model.training {
                    Button("Try Again") { model.retryTraining() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                } else {
                    Button("Test It") { model.beginProof() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(model.training != .done)
                }
            }
        }
    }

    private var title: String {
        switch model.training {
        case .done: return "Your model is trained"
        case .failed: return "The training stopped"
        default: return "Training your model"
        }
    }

    private var fraction: Double {
        switch model.training {
        case .waiting: return 0
        case .reading(let done, let total): return 0.1 * Double(done) / Double(max(total, 1))
        case .learning(let pass, let of, _): return 0.1 + 0.85 * Double(pass) / Double(max(of, 1))
        case .checking: return 0.97
        case .done: return 1
        case .failed: return 0
        }
    }

    private var line: String {
        // A time left that stopped moving is worse than none.
        if model.trainingSilent { return "Still working…" }
        switch model.training {
        case .waiting: return "Starting…"
        case .reading(_, let total): return "Reading your \(total.formatted()) pictures…"
        case .learning(let pass, let of, let left):
            guard let left else { return "Pass \(pass) of \(of). Measuring how long a pass takes on this Mac…" }
            return "Pass \(pass) of \(of). About \(Self.duration(left)) left."
        case .checking: return "Checking the finished model…"
        case .done: return result
        case .failed: return ""
        }
    }

    /// What the training produced, in numbers a person can check.
    private var result: String {
        guard let info = model.info else { return "Done." }
        return "Trained on \(info.pictures.formatted()) pictures from \(Format.count(info.sessions.count, "recording")) "
            + "in \(Self.duration(info.seconds)). "
            + "Shown the same pictures again, unaltered, it calls \(info.rightOnOwnPictures.formatted()) of them right. "
            + "That is the easy test, since it has seen them. The real one is next."
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(max(1, Int(seconds.rounded()))) s" : "\(Int((seconds / 60).rounded())) min"
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: fraction)
                .tint(model.training == .done ? .green : .accentColor)
                .animation(.easeOut(duration: 0.3), value: fraction)
            Text(line)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failure(reason: String, attempts: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 8) {
                Text(attempts < 2 ? "It stopped before the end" : "It stopped again").font(.headline)
                Text(TrainingFailureWords.plain(reason))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your recordings are kept, and no half-made model was installed. "
                     + (attempts < 2 ? "Trying again is usually enough." : TrainingFailureWords.advice))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The first failure may be a passing one. After a second, there must be
                // somewhere to take it: the details to copy, and a place to report them.
                if attempts >= 2 {
                    HStack(spacing: 10) {
                        Button("Copy the Details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reason, forType: .string)
                        }
                        if let page = TrainingFailureWords.reportPage {
                            Button("Report It") { NSWorkspace.shared.open(page) }
                                .help("Opens the project's page in your browser. Blink Monitor itself sends nothing.")
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A few of your own pictures, as this pass shows them to the model.
private struct Samples: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        if !model.alteredSamples.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(Array(model.alteredSamples.enumerated()), id: \.offset) { _, image in
                        EyeThumbnail(image: image, side: 101)
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String {
        if case .learning = model.training { return "Six of your pictures, as the model is shown them during this pass." }
        return "Six of your pictures: three with the eyes open, three closed."
    }
}

// MARK: - Test

private struct ProofPage: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle("Test it: blink, and watch it count",
                      "The real test: blink ten times and see how many it counts.")
            HStack(alignment: .center, spacing: 26) {
                ProofRing(model: model)
                VStack(alignment: .leading, spacing: 12) {
                    Text(headline)
                        .font(.system(size: 19, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TickDots(test: model.proofTest, running: model.proof == .running)
                }
            }
            .padding(.vertical, 6)
            HStack(spacing: 10) {
                if model.camera == .on && !model.faceFound && model.proof != .running {
                    Text("No face in view: the test can start once the camera sees you.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if case .refused = model.camera {
                    Text("Camera access was refused: allow it in System Settings, then open the setup again.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 12)
                buttons
            }
        }
    }

    private var result: ProofTest.Result? {
        if case .finished(let result) = model.proof { return result }
        return nil
    }

    private var headline: String {
        switch model.proof {
        case .ready: return "10 ticks. Blink once at each."
        case .running: return model.proofTest.answered.isEmpty ? "Get ready" : "Blink at each tick"
        case .finished(let result):
            return result.passed ? "\(result.found) of \(result.of) blinks counted" : "Only \(result.found) of \(result.of) blinks counted"
        }
    }

    private var explanation: String {
        switch model.proof {
        case .ready:
            return "The ticks come a second and a half apart. Blink quickly and lightly, the way you blink without thinking: "
                + "those are the ones that get missed. It takes fifteen seconds."
        case .running:
            return "The ring fills at each blink the model counts. The eye in the menu bar blinks with you too."
        case .finished(let result):
            var text: String
            if result.found == result.of {
                text = "Your model sees your blinks."
            } else if result.passed {
                text = "Good enough to count on. The lightest blinks are the hardest to see; one more recording in this light would help."
            } else if model.failedTests < 2 {
                text = "Too few to trust the count. A missed tick is the usual reason: test again, and blink at each tick as it sounds, "
                    + "lightly but all the way down."
            } else {
                text = "Too few again. One more recording, where you sit now, usually fixes it: "
                    + "the model then learns from eyes in this light."
            }
            if result.extra > 0 {
                text += " It also counted \(Format.count(result.extra, "blink")) between the ticks, which may well be yours."
            }
            return text
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.proof {
        case .ready:
            Button("Start the Test") { model.startTest() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.canStartTest)
        case .running:
            Button("Start Again") { model.testAgain() }
                .controlSize(.large)
        case .finished(let result):
            if result.passed {
                Button("Test Again") { model.testAgain() }
                    .controlSize(.large)
                Button("Finish") { model.finish() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else {
                if model.hasPrevious {
                    Button("Go Back to the Model I Had") { model.goBackToPrevious() }
                }
                Button("Use It Anyway") { model.useAnyway() }
                    .help("The app will count with this model and may miss blinks, so your rate can read lower than it is. You can test or record again later in Settings > Your Model.")
                // A first failure is often a missed tick: the test again comes first.
                // After a second one, two more minutes of recording are worth it.
                if model.failedTests < 2 {
                    Button("Record One More") { model.recordOneMore() }
                        .controlSize(.large)
                    Button("Test Again") { model.testAgain() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                } else {
                    Button("Test Again") { model.testAgain() }
                        .controlSize(.large)
                    Button("Record One More") { model.recordOneMore() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
        }
    }
}

/// The count, in a ring that fills with each blink the model counted at a tick.
private struct ProofRing: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        let found = model.proofTest.answered.filter { $0 }.count
        let finished: ProofTest.Result? = { if case .finished(let result) = model.proof { return result } else { return nil } }()
        let colour: Color = finished.map { $0.passed ? .green : .orange } ?? .green
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 12)
            Circle()
                .trim(from: 0, to: Double(finished?.found ?? found) / Double(ProofTest.ticks))
                .stroke(colour, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: found)
            // A soft disc while the model reads your eyes as closed: it is watching.
            Circle()
                .fill(Color.green.opacity(model.eyesClosed && model.proof == .running ? 0.14 : 0))
                .padding(14)
            if let finished, finished.found == finished.of {
                Image(systemName: "checkmark")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: -2) {
                    Text("\(finished?.found ?? found)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(ProofTest.ticks)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 160, height: 160)
        .padding(6)                              // the ring's line is drawn half outside its circle
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(finished?.found ?? found) of \(ProofTest.ticks) blinks counted")
    }
}

/// One dot per tick: filled when a blink answered it, hollow when none did.
private struct TickDots: View {
    let test: ProofTest
    let running: Bool

    var body: some View {
        let answered = test.answered
        HStack(spacing: 7) {
            ForEach(0..<ProofTest.ticks, id: \.self) { index in
                ZStack {
                    if index < answered.count {
                        // The tick being answered right now is not yet a miss.
                        let pending = running && index == answered.count - 1 && !answered[index]
                        Circle().fill(answered[index] ? Color.green : (pending ? Color.accentColor.opacity(0.35) : Color.clear))
                        if !answered[index] && !pending { Circle().stroke(Color.orange, lineWidth: 2) }
                    } else {
                        Circle().fill(Color.primary.opacity(0.12))
                    }
                }
                .frame(width: 13, height: 13)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Done

private struct DonePage: View {
    @ObservedObject var model: SetupModel
    let actions: SetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isDemo ? "That was the whole setup" : "Blink Monitor is counting your blinks")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 14) {
                MenuBarSketch()
                VStack(alignment: .leading, spacing: 2) {
                    Text("From now on, look up").fontWeight(.semibold)
                    Text("Blink Monitor has no window and no Dock icon. It lives in the menu bar, at the top right of the screen: click the eye.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 12) {
                if model.isDemo {
                    WelcomePoint(symbol: "sparkles", title: "Nothing was kept",
                                 text: "The painted recordings and the model trained on them are in a temporary folder, emptied at the next demo.")
                } else {
                    WelcomePoint(symbol: "folder", title: "Your recordings and your model stay on this Mac",
                                 text: String(format: "%.0f MB, in a folder only your account can read: %@", model.megabytesOnDisk,
                                              model.place))
                    NotificationPoint(reminders: model.monitor.reminders, actions: actions)
                    WelcomePoint(symbol: "slider.horizontal.3", title: "Also in Settings",
                                 text: """
                                     Look-away breaks (20-20-20): off until you switch them on.
                                     Routines: eye drops, a heated mask, or your own.
                                     Your Model: add a session in another light, or delete the recordings and the model.
                                     """)
                    LoginPoint(loginItem: model.monitor.loginItem)
                }
            }

            HStack {
                if !model.isDemo {
                    Button("Show the Files") { actions.showFiles() }
                    Button("Open Settings") { actions.openSettings() }
                }
                Spacer()
                if !model.isDemo {
                    Button("Watch It Count") { actions.watchItCount() }
                        .controlSize(.large)
                        .help("Opens Live View: the camera's picture, your two eyes, and each blink as it is counted.")
                }
                Button("Done") { actions.done() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }

    private var summary: String {
        guard let info = model.info, let proof = info.proof else { return "Setup is finished." }
        return "Your model was trained on \(info.pictures.formatted()) pictures of your eyes, and counted "
            + "\(proof.found) of \(proof.of) blinks in its test."
    }
}

/// The notification question, said where it can be answered: macOS asks in a small
/// banner at the top right that leaves after a few seconds, and a banner nobody saw
/// counts as a refusal. The line follows what macOS answered.
private struct NotificationPoint: View {
    @ObservedObject var reminders: ReminderController
    let actions: SetupActions

    var body: some View {
        switch reminders.notifications {
        case .unknown:
            WelcomePoint(symbol: "bell", title: "macOS is asking about notifications",
                         text: "Look at the top right of the screen and choose Allow. If the question has gone, it waits in Notification Centre: click the clock in the menu bar. "
                             + "Reminders come as notifications: one when your blink rate stays low for a few minutes, and less often while you leave it unanswered.")
        case .allowed:
            WelcomePoint(symbol: "bell", title: "Notifications are allowed",
                         text: "One reminder when your blink rate stays low for a few minutes, and less often while you leave it unanswered. "
                             + "A reminder's buttons show when the pointer is over it.")
        case .refused:
            VStack(alignment: .leading, spacing: 6) {
                WelcomePoint(symbol: "bell.slash", title: "Notifications are not allowed",
                             text: "A reminder is then a sound only, with no words. You can allow them in System Settings > Notifications > Blink Monitor.")
                Button("Open Notification Settings") { actions.openNotificationSettings() }
                    .padding(.leading, 42)
            }
        }
    }
}

/// Start at login, offered once at the end of the setup. A menu-bar app has no Dock
/// icon to remind anyone of it: after the first restart it would simply be gone.
private struct LoginPoint: View {
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        if loginItem.available {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "power")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                Toggle(isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start Blink Monitor when I log in").fontWeight(.semibold)
                        Text(loginItem.problem ?? "Without this, it is gone after a restart until you open it again. You can change it in Settings > General.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
}

// MARK: - Shared pieces

private struct PageTitle: View {
    private let title: String
    private let subtitle: String

    init(_ title: String, _ subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
