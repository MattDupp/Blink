import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The recording page: the voice's poses, the counts, and what to do after each session.

struct RecordPage: View {
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
                                .textStyle(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Text(footnote)
                    .textStyle(.callout)
                    .foregroundStyle((model.faceFound && !model.soundMuted) || model.sessionRunning ? Color.secondary : Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                buttons
            }
        }
    }

    private var footnote: String {
        if model.sessionRunning { return "Keep your face in front of the camera. Blink whenever you need to. The window's brightness changes once when a closed-eye pose ends." }
        if model.camera == .on && !model.faceFound { return "No face in view: recording can start once the camera sees you." }
        if !model.parts.ownSessions {
            return "Recordings are saved in \(model.parts.sessionsRoot.path), the folder named when the app was started."
        }
        if model.soundMuted {
            return "The Mac's sound is off: you would not hear the voice that guides you. Turn it up, then press Play the Voice. "
                + "Without sound: read each pose here, and open your eyes when the window's brightness changes."
        }
        return "Sound on: the voice is your guide while your eyes are closed. The window's brightness also changes once when a closed-eye pose ends."
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
                .mainButton()
                .controlSize(.large)
        } else {
            Button("Play the Voice") { model.playVoice() }
                .controlSize(.large)
                .help("Says one sentence, to check that you can hear the guide before you close your eyes.")
            Button("Start Recording \(model.nextSession)") { model.startSession() }
                .mainButton()
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
                        .textStyle(.headline)
                    Spacer()
                    if model.phaseState == .recording {
                        Circle().fill(Color.red).frame(width: 8, height: 8).accessibilityHidden(true)
                    }
                    Text(stateText)
                        .textStyle(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(phase.instruction)
                    .textStyle(.title, weight: .semibold)
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
                    .textStyle(.title, weight: .bold, design: .rounded)
                if let note = model.sessionNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.warningText)
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
                    ["A voice asks for \(SessionScript.phases.count) poses, \(Format.word(Int(SessionPace.usual.recordSeconds))) seconds each: about two minutes.",
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
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
            }
            // One quiet line that moves, where two counters read like a data tool.
            let saved = model.sessions.reduce(0) { $0 + $1.pictures } + (model.sessionRunning ? model.sessionOpen + model.sessionClosed : 0)
            Text(saved > 0 ? "\(saved.formatted()) pictures saved so far, each with the pose it was taken in."
                           : "Ten pictures a second are saved during each pose, each with the pose it was taken in.")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Train
