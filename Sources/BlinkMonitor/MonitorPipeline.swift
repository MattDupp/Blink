import Foundation
import CoreGraphics
import CoreVideo
import BlinkCore

/// What one processed frame tells the rest of the app.
struct MonitorUpdate {
    var time = 0.0
    var preview: CGImage?
    var frameSize: CGSize = .zero
    var eyeRects: [CGRect] = []
    var faceFound = false
    /// The model's answer for this frame (the average of the eyes it could read).
    var probability: Double?
    var event: BlinkDetector.Event?
    var eyesClosed = false

    var totalBlinks = 0
    var longClosures = 0
    var observedSeconds = 0.0
    var blinksLastMinute = 0
    var ratePerMinute: Double?
    var lastBlinkSeconds: Double?

    /// A minute of the clock that just ended (see MinuteAggregator).
    var completedMinute: MinuteRecord?
    /// The minute being filled; sent about once a second.
    var currentMinute: MinuteRecord?
    var error: String?
}

/// The whole pipeline, run on every camera frame:
///
///     frame -> find the eyes (Vision) -> cut 64x64 pictures -> model: closed?  -> blink?
///              EyeLocator                EyeCropper            EyeClassifier     BlinkDetector
///
/// The first two steps are the very code the recorder used: the model receives pictures
/// made exactly like the ones it was trained on.
final class MonitorPipeline: @unchecked Sendable {

    /// Called on the camera queue after every frame.
    var onUpdate: ((MonitorUpdate) -> Void)?

    private let locator = EyeLocator()
    private let cropper = EyeCropper()
    private let classifier: EyeClassifier
    private var detector = BlinkDetector()
    private var stats = BlinkStats()
    private var minutes = MinuteAggregator()
    private var frameIndex = 0

    private let lock = NSLock()
    private var resetRequested = false
    private var previewWanted = false
    private var capture: CaptureWriter?
    private var tickPending = false

    init(classifier: EyeClassifier) {
        self.classifier = classifier
    }

    /// Asks for the live counters to start again from zero (called from the main thread;
    /// carried out on the camera queue at the next frame). The history is not touched.
    func requestReset() {
        lock.lock()
        resetRequested = true
        lock.unlock()
    }

    /// The camera picture is only prepared while a window shows it. In the background
    /// nobody looks at it, and converting 15 full frames a second would be the single
    /// most expensive thing the app does.
    func setPreview(_ wanted: Bool) {
        lock.lock()
        previewWanted = wanted
        lock.unlock()
    }

    /// Starts (a writer) or stops (nil) recording every frame for later study.
    func setCapture(_ writer: CaptureWriter?) {
        lock.lock()
        capture = writer
        tickPending = false
        lock.unlock()
    }

    /// A cue sound was just played: the next frame is marked in the capture.
    func markTick() {
        lock.lock()
        tickPending = true
        lock.unlock()
    }

    func process(_ pixelBuffer: CVPixelBuffer, time: Double) {
        frameIndex += 1

        lock.lock()
        let reset = resetRequested
        resetRequested = false
        let preview = previewWanted
        let capture = self.capture
        let tick = tickPending
        tickPending = false
        lock.unlock()
        if reset {
            detector.reset()
            stats = BlinkStats()
        }

        var update = MonitorUpdate()
        update.time = time
        update.frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        // One answer per readable eye, then their average. Both eyes blink together, so
        // averaging two readings of the same event halves the noise of each.
        var eyes: [CapturedEye] = []
        do {
            if let located = try locator.locate(in: pixelBuffer) {
                update.faceFound = true
                update.eyeRects = located.usableEyes.map { $0.cropRect }
                for eye in located.usableEyes {
                    if let picture = cropper.crop(pixelBuffer, rect: eye.cropRect) {
                        eyes.append(CapturedEye(side: eye.side, picture: picture,
                                                closed: try classifier.closedProbability(of: picture),
                                                openness: Double(eye.openness)))
                    }
                }
            }
        } catch {
            update.error = "\(error)"
        }
        if !eyes.isEmpty {
            update.probability = eyes.reduce(0) { $0 + $1.closed } / Double(eyes.count)
        }

        let watched = stats.frame(time: time, eyesRead: update.probability != nil)
        var newBlinks = 0
        if let event = detector.update(time: time, closed: update.probability) {
            stats.record(event)
            update.event = event
            if case .blink = event { newBlinks = 1 }
        }
        if case .closed = detector.state { update.eyesClosed = true }

        // The history is kept by the clock on the wall, not the camera's own clock:
        // "at 10:15 you blinked 11 times" is what will be read later.
        update.completedMinute = minutes.add(at: Date(), observedSeconds: watched, blinks: newBlinks)
        if frameIndex % 30 == 0 || update.completedMinute != nil {
            update.currentMinute = minutes.current
        }

        capture?.write(frame: frameIndex, time: time, eyes: eyes, mean: update.probability,
                       state: detector.state, event: update.event, tick: tick)

        update.totalBlinks = stats.totalBlinks
        update.longClosures = stats.longClosures
        update.observedSeconds = stats.observedSeconds
        update.blinksLastMinute = stats.blinks(inLast: 60, now: time)
        update.ratePerMinute = stats.ratePerMinute(inLast: 60, now: time)
        update.lastBlinkSeconds = stats.lastBlink?.duration

        if preview && frameIndex % 2 == 0 {
            update.preview = cropper.preview(pixelBuffer, maxWidth: 640)
        }
        onUpdate?(update)
    }
}
