import SwiftUI
import BlinkCore
import BlinkUI

/// The recorder's window: the instruction on top, the camera with the two squares on the
/// left, the two 64x64 pictures the model will learn from on the right, the controls below.
struct RecorderView: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 14) {
            PromptBanner(model: model)
            HStack(alignment: .top, spacing: 14) {
                CameraPreview(model: model)
                SidePanel(model: model)
                    .frame(width: 250)
            }
            Controls(model: model)
        }
        .padding(16)
        .frame(minWidth: 1020, minHeight: 660)
        .task { await model.start() }
    }
}

// MARK: - Instruction

private struct PromptBanner: View {
    @ObservedObject var model: RecorderModel

    private var tint: Color {
        switch model.currentLabel {
        case .open: return .green
        case .closed: return .indigo
        case nil: return .gray
        }
    }

    private var stateText: String {
        switch model.phaseState {
        case .idle: return ""
        case .listening: return "Listen"
        case .settling: return "Get ready"
        case .recording: return "RECORDING"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.sessionRunning {
                    Text("Pose \(model.phaseIndex + 1) of \(SessionScript.phases.count)")
                        .font(.headline)
                    Spacer()
                    Text(stateText)
                        .font(.headline)
                        .foregroundStyle(model.phaseState == .recording ? Color.red : Color.secondary)
                }
            }
            Text(model.prompt)
                .font(.system(size: 26, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            // The bar fills while a pose is being recorded.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(tint).frame(width: geometry.size.width * model.recordProgress)
                }
            }
            .frame(height: 6)
        }
        .padding(14)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Camera

private struct CameraPreview: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        CameraPreviewView(image: model.preview, frameSize: model.frameSize, eyeRects: model.eyeRects,
                          placeholder: CameraNote.text(for: model.lifecycle, appName: "Blink Recorder"))
    }
}

// MARK: - What the model will see

private struct SidePanel: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What the model will see")
                .font(.headline)
            HStack(spacing: 10) {
                EyeThumbnail(image: model.leftCrop, caption: "left of picture")
                EyeThumbnail(image: model.rightCrop, caption: "right of picture")
            }
            Text(model.faceFound
                 ? "Each square is \(model.cropSide) px in the camera picture, saved as \(EyeCropper.outputSize) x \(EyeCropper.outputSize)."
                 : "No face found.")
                .font(.callout)
                .foregroundStyle(model.faceFound ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("The camera view is not mirrored: it is exactly what is recorded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("This session")
                .font(.headline)
            Text("\(model.sessionOpen) open, \(model.sessionClosed) closed")
                .monospacedDigit()

            Text("On disk")
                .font(.headline)
            Text("\(model.dataset.sessions) sessions: \(model.dataset.open) open, \(model.dataset.closed) closed")
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)

            if let problem = model.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct EyeThumbnail: View {
    let image: CGImage?
    let caption: String

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black
                if let image {
                    // No smoothing: you see the real 64x64 pixels, as the model gets them.
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Controls

private struct Controls: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 12) {
            TextField("Conditions of this session (daylight, lamp, glasses...)", text: $model.condition)
                .textFieldStyle(.roundedBorder)
                .disabled(model.sessionRunning)

            Button("Show pictures") { model.revealData() }

            // A session that went wrong is thrown away whole, after one confirmation.
            Button("Discard last session") { model.confirmingDiscard = true }
                .disabled(model.sessionRunning || model.lastSessionFolder == nil)
                .confirmationDialog(
                    "Move session \(model.lastSessionFolder?.lastPathComponent ?? "") to the Trash?",
                    isPresented: $model.confirmingDiscard
                ) {
                    Button("Move to Trash", role: .destructive) { model.discardLastSession() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All its pictures go with it. The other sessions are kept.")
                }

            if model.sessionRunning {
                Button("Stop") { model.stopSession() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Start session") { model.startSession() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStartSession)
            }
        }
    }
}
