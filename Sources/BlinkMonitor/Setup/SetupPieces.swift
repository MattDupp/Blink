import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// Pieces several pages of the setup share: the camera picture, the eyes, the checks, the
// title, and what to do when the camera does not start.

struct Check {
    enum State { case waiting, good, warning }
    let state: State
    let title: String
    let detail: String
}

struct CheckRow: View {
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
                        .textStyle(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The camera picture with the eye squares, as the setup shows it.
struct SetupCamera: View {
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
        case .refused: return CameraNote.blocked(appName: "Blink")
        case .failed: return "The camera could not be started."
        case .off, .on: return model.cameraSilent ? CameraNote.silent : "Starting the camera…"
        }
    }
}

/// The two 64x64 pictures cut from the frame: what is recorded, and what the model reads.
struct EyePair: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            EyeThumbnail(image: model.leftCrop)
            EyeThumbnail(image: model.rightCrop)
            VStack(alignment: .leading, spacing: 2) {
                Text("What the model sees")
                    .textStyle(.callout, weight: .semibold)
                Text("Two small pictures, \(EyeCropper.outputSize) pixels across. Nothing else of the camera picture is ever saved.")
                    .textStyle(.callout)
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

struct PageTitle: View {
    private let title: String
    private let subtitle: String

    init(_ title: String, _ subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .textStyle(.title, weight: .bold, design: .rounded)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What can keep the camera from giving pictures, worded for the window.
struct CameraTrouble {
    let title: String
    let text: String
    let refused: Bool

    init?(_ state: SetupModel.CameraState) {
        switch state {
        case .refused:
            title = String(CameraNote.blocked(appName: "Blink").dropLast())
            text = CameraNote.unblock(appName: "Blink") + " macOS may then ask to quit and reopen "
                + "Blink: say yes, the setup goes on from this page."
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

struct CameraTroubleCard: View {
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
                Text(trouble.title).textStyle(.headline)
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
