import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The camera page: a face in view, eyes large enough, light enough.

struct CameraPage: View {
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
                        // With more than one camera, this is the moment to choose: the
                        // model learns your eyes as THIS camera shows them.
                        if model.cameras.count > 1 {
                            VStack(alignment: .leading, spacing: 4) {
                                Picker("Camera", selection: Binding(get: { model.chosenCamera ?? "" },
                                                                    set: { model.chooseCamera($0.isEmpty ? nil : $0) })) {
                                    Text("Automatic").tag("")
                                    Divider()
                                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                                }
                                .fixedSize()
                                Text("Record with the camera you will sit in front of. Automatic is the Mac's own.")
                                    .textStyle(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            HStack {
                Text("Why: a recording of an empty chair, or of eyes too small to read, teaches the model nothing.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Back") { model.backToWelcome() }
                    .controlSize(.large)
                    .help("To the first page, where the demo is offered. The camera turns off.")
                Button("Continue") { model.cameraLooksRight() }
                    .mainButton()
                    .controlSize(.large)
                    .disabled(!model.canLeaveCameraCheck)
            }
        }
    }

    private var checks: [Check] {
        let watching = model.camera == .on
        var checks: [Check] = []
        if watching && model.cameraSilent {
            checks.append(Check(state: .warning, title: String(CameraNote.silent.dropLast()),
                                detail: CameraNote.silentAdvice(model.monitor.cameraPlace)))
        } else if model.faceInView {
            checks.append(Check(state: .good, title: "Your face is in view", detail: "Stay where you are comfortable: that is where it will watch you."))
        } else if watching && model.faceMissing {
            checks.append(Check(state: .warning, title: "No face found",
                                detail: CameraNote.faceIt(model.monitor.cameraPlace)))
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
