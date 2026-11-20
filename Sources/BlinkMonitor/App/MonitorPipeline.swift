import Foundation
import CoreGraphics
import CoreVideo
import BlinkCore

/// What the camera thread tells the rest of the app.
struct MonitorUpdate {
    var time = 0.0
    var preview: CGImage?
    var frameSize: CGSize = .zero
    var eyeRects: [CGRect] = []
    var faceFound = false
    /// The model's answer for this frame (the eyes combined), nil when no eye was read.
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
    /// Stage timings over the last two seconds (for the diagnostics window).
    var timings: StageTimings.Summary?
    /// Stage timings over the last minute (for the performance log).
    var minuteTimings: StageTimings.Summary?
    var error: String?
}

/// Everything that happens on the camera's thread, for every frame:
///
///     frame -> EyeReader (find eyes, crop, model) -> BlinkDetector -> statistics -> update
///
/// TWO THINGS KEEP IT CHEAP IN THE BACKGROUND:
///   - No face, no work. After 3 s without a face, only one frame in six is analysed
///     (enough to notice your return within a fifth of a second). An empty chair costs
///     almost nothing.
///   - The rest of the app is only told what it needs. With no window open, an update is
///     sent when something changes (a blink, a face, a minute) and once a second -
///     not 30 times a second.
final class MonitorPipeline: @unchecked Sendable {

    /// Called on the camera queue. Not every frame: see `shouldSend`.
    var onUpdate: ((MonitorUpdate) -> Void)?

    static let idleAfterFrames = 90      // 3 s at 30 frames a second
    static let idleStride = 6

    private let reader: EyeReader
    private var detector = BlinkDetector()
    private var stats = BlinkStats()
    private var minutes = MinuteAggregator()
    private var recentTimings = StageTimings()
    private var minuteTimings = StageTimings()

    private var frameIndex = 0
    private var framesWithoutFace = 0
    private var lastSent = MonitorUpdate()
    private var lastTimingsAt = 0.0
    private var lastMinuteTimingsAt = 0.0

    private let lock = NSLock()
    private var resetRequested = false
    private var liveView = false
    private var capture: CaptureWriter?
    private var tickPending = false

    init(classifier: EyeClassifier) {
        reader = EyeReader(classifier: classifier)
    }

    // MARK: - Requests from the main thread

    /// The live counters start again from zero at the next frame. The history is not touched.
    func requestReset() {
        lock.lock()
        resetRequested = true
        lock.unlock()
    }

    /// A window is showing the camera and the curve: prepare the picture, send every frame.
    func setLiveView(_ on: Bool) {
        lock.lock()
        liveView = on
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

    // MARK: - Every frame

    func process(_ pixelBuffer: CVPixelBuffer, time: Double) {
        frameIndex += 1
        let clock = StageTimings.now()
        recentTimings.frameDelivered(at: clock)
        minuteTimings.frameDelivered(at: clock)

        lock.lock()
        let reset = resetRequested
        resetRequested = false
        let live = liveView
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

        // No face for 3 s: analyse one frame in six. A capture always gets every frame.
        let idle = framesWithoutFace >= Self.idleAfterFrames && capture == nil
        var reading = FrameReading()
        if !idle || frameIndex % Self.idleStride == 0 {
            do {
                reading = try reader.read(pixelBuffer)
                recentTimings.record(findEyes: reading.findEyesSeconds, crop: reading.cropSeconds,
                                     model: reading.modelSeconds, total: reading.totalSeconds)
                minuteTimings.record(findEyes: reading.findEyesSeconds, crop: reading.cropSeconds,
                                     model: reading.modelSeconds, total: reading.totalSeconds)
            } catch {
                update.error = "\(error)"
                Log.pipeline.error("Frame not read: \(String(describing: error), privacy: .public)")
            }
            framesWithoutFace = reading.faceFound ? 0 : framesWithoutFace + 1
        }
        update.faceFound = reading.faceFound
        update.eyeRects = reading.eyeRects
        update.probability = reading.closed

        let watched = stats.frame(time: time, eyesRead: reading.closed != nil)
        var newBlinks = 0
        if let event = detector.update(time: time, closed: reading.closed) {
            stats.record(event)
            update.event = event
            if case .blink = event { newBlinks = 1 }
        }
        if case .closed = detector.state { update.eyesClosed = true }

        // The history is kept by the clock on the wall, not the camera's own clock:
        // "at 10:15 you blinked 11 times" is what will be read later.
        update.completedMinute = minutes.add(at: Date(), observedSeconds: watched, blinks: newBlinks)
        update.currentMinute = minutes.current

        capture?.write(frame: frameIndex, time: time, reading: reading,
                       state: detector.state, event: update.event, tick: tick)

        update.totalBlinks = stats.totalBlinks
        update.longClosures = stats.longClosures
        update.observedSeconds = stats.observedSeconds
        update.blinksLastMinute = stats.blinks(inLast: 60, now: time)
        update.ratePerMinute = stats.ratePerMinute(inLast: 60, now: time)
        update.lastBlinkSeconds = stats.lastBlink?.duration

        if clock - lastTimingsAt >= 2 {
            update.timings = recentTimings.takeSummary(at: clock)
            lastTimingsAt = clock
        }
        if clock - lastMinuteTimingsAt >= 60 {
            update.minuteTimings = minuteTimings.takeSummary(at: clock)
            lastMinuteTimingsAt = clock
        }

        if live && frameIndex % 2 == 0 {
            update.preview = reader.preview(pixelBuffer, maxWidth: 640)
        }
        if shouldSend(update, live: live) {
            lastSent = update
            onUpdate?(update)
        }
    }

    /// With a window open every frame matters (the curve). In the background, only what
    /// would change the menu bar or the history - plus one update a second as a heartbeat.
    private func shouldSend(_ update: MonitorUpdate, live: Bool) -> Bool {
        if live || frameIndex % 30 == 0 { return true }
        if update.event != nil || update.completedMinute != nil || update.error != nil { return true }
        if update.minuteTimings != nil { return true }
        if update.faceFound != lastSent.faceFound { return true }
        return update.ratePerMinute?.rounded() != lastSent.ratePerMinute?.rounded()
    }
}
