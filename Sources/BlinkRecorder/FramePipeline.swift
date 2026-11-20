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
    var leftCrop: CGImage?
    var rightCrop: CGImage?
    var savedOpen = 0
    var savedClosed = 0
    var error: String?
}

/// The work done on every camera frame, in order:
///
///     frame -> find the eyes (Vision) -> cut two 64x64 pictures -> save them (when recording)
///
/// It runs on the camera's background queue. The session script runs on the main thread
/// and only tells it WHAT is being recorded, through `setRecording`; a lock protects that
/// one shared value, because two threads reading and writing the same variable without
/// one is a data race.
///
/// `@unchecked Sendable` is our promise to the compiler that this object may be shared
/// between threads: it cannot verify a lock by itself, so we vouch for it.
final class FramePipeline: @unchecked Sendable {

    struct Recording {
        let writer: SessionWriter
        let phaseIndex: Int
        let phase: Phase
    }

    /// Called on the camera queue after every frame.
    var onUpdate: ((FrameUpdate) -> Void)?

    private let locator = EyeLocator()
    private let cropper = EyeCropper()
    private let lock = NSLock()
    private var recording: Recording?
    private var frameIndex = 0

    func setRecording(_ value: Recording?) {
        lock.lock()
        recording = value
        lock.unlock()
    }

    func process(_ pixelBuffer: CVPixelBuffer, time: Double) {
        frameIndex += 1
        var update = FrameUpdate()
        update.frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        var located: LocatedEyes?
        do {
            located = try locator.locate(in: pixelBuffer)
        } catch {
            update.error = "Vision failed: \(error.localizedDescription)"
        }

        var crops: [(eye: EyeRegion, image: CGImage)] = []
        if let located {
            update.faceFound = true
            // Only the usable eyes are drawn, cut and saved: with the head turned far to
            // one side that is the near eye alone (see LocatedEyes.usableEyes).
            update.eyeRects = located.usableEyes.map { $0.cropRect }
            update.cropSide = Int(located.left.cropRect.width)
            for eye in located.usableEyes {
                if let image = cropper.crop(pixelBuffer, rect: eye.cropRect) {
                    crops.append((eye, image))
                    if eye.side == .imageLeft { update.leftCrop = image } else { update.rightCrop = image }
                }
            }
        }

        lock.lock()
        let current = recording
        lock.unlock()

        // Save only when every usable eye was cut cleanly, and only one frame out of three.
        if let current, let located, !crops.isEmpty, crops.count == located.usableEyes.count,
           frameIndex % SessionScript.saveEveryNthFrame == 0 {
            for crop in crops {
                let saved = current.writer.save(Sample(image: crop.image, phaseIndex: current.phaseIndex,
                                                       phase: current.phase, frameIndex: frameIndex, time: time,
                                                       eye: crop.eye, located: located, frameSize: update.frameSize))
                if saved {
                    if current.phase.label == .open { update.savedOpen += 1 } else { update.savedClosed += 1 }
                } else {
                    update.error = "A picture could not be written to disk."
                }
            }
        }

        // The window shows every second frame: 15 pictures a second look live enough,
        // and converting a full frame for display is the most expensive step here.
        if frameIndex % 2 == 0 {
            update.preview = cropper.preview(pixelBuffer, maxWidth: 960)
        }
        onUpdate?(update)
    }
}
