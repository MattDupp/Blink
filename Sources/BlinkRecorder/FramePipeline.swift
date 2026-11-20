import Foundation
import CoreGraphics
import CoreVideo
import BlinkCore

/// What one processed frame tells the window.
struct FrameUpdate {
    var preview: CGImage?
    var frameSize: CGSize = .zero
    var eyeRects: [CGRect] = []
    var faceFound = false
    var cropSide = 0
    /// The pictures that would be saved, as shown beside the camera. An eye that is not
    /// usable in this frame is missing: what is shown is what is saved.
    var leftCrop: CGImage?
    var rightCrop: CGImage?
    var savedOpen = 0
    var savedClosed = 0
    var error: String?
}

/// The work done on every camera frame, in order:
///
///     frame -> EyeFinder (find the eyes, cut 64x64 pictures) -> save them (when recording)
///
/// `EyeFinder` is the very stage the monitor reads its eyes through, so the pictures saved
/// here are made exactly like the ones the model will be asked about.
///
/// It runs on the camera's background queue. The session script runs on the main thread
/// and only tells it WHAT is being recorded, through `setRecording`.
final class FramePipeline: @unchecked Sendable {

    struct Recording {
        let writer: SessionWriter
        let phaseIndex: Int
        let phase: Phase
    }

    /// Called on the camera queue after every frame.
    var onUpdate: ((FrameUpdate) -> Void)?

    private let finder = EyeFinder()
    private let recording = Locked<Recording?>(nil)
    private var frameIndex = 0

    func setRecording(_ value: Recording?) {
        recording.withLock { $0 = value }
    }

    func process(_ pixelBuffer: CVPixelBuffer, time: Double) {
        frameIndex += 1
        var update = FrameUpdate()
        update.frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        do {
            // A recorder searches for the eyes on every frame: each saved picture gets its
            // own, fresh square.
            var cost = FrameCost()
            if case .found(let found) = try finder.find(in: pixelBuffer, everyFrame: true, cost: &cost) {
                show(found, in: &update)
                if frameIndex % SessionScript.saveEveryNthFrame == 0, let current = recording.withLock({ $0 }) {
                    save(found, to: current, time: time, update: &update)
                }
            }
        } catch {
            update.error = "Vision failed: \(error.localizedDescription)"
        }

        // The window shows every second frame: 15 pictures a second look live enough,
        // and converting a full frame for display is the most expensive step here.
        if frameIndex % 2 == 0 {
            update.preview = finder.preview(pixelBuffer, maxWidth: 960)
        }
        onUpdate?(update)
    }

    private func show(_ found: FoundEyes, in update: inout FrameUpdate) {
        update.faceFound = true
        update.eyeRects = found.located.usableEyes.map(\.cropRect)
        update.cropSide = Int(found.located.left.cropRect.width)
        for crop in found.crops {
            let image = EyeCropper.image(from: crop.picture)
            if crop.region.side == .imageLeft { update.leftCrop = image } else { update.rightCrop = image }
        }
    }

    /// Saves the frame's pictures - only when every usable eye was cut cleanly.
    private func save(_ found: FoundEyes, to current: Recording, time: Double, update: inout FrameUpdate) {
        guard found.isComplete else { return }
        for crop in found.crops {
            guard let image = EyeCropper.image(from: crop.picture) else { continue }
            let saved = current.writer.save(EyeSample(
                image: image, label: current.phase.label, variant: current.phase.variant,
                phaseIndex: current.phaseIndex, frameIndex: frameIndex, time: time,
                eye: crop.region, located: found.located, frameSize: update.frameSize))
            if !saved {
                update.error = "A picture could not be written to disk."
            } else if current.phase.label == .open {
                update.savedOpen += 1
            } else {
                update.savedClosed += 1
            }
        }
    }
}
