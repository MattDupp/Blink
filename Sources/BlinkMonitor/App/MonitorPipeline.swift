import Foundation
import CoreGraphics
import CoreVideo
import BlinkCore

/// What the pipeline knows right now, as one value: the eyes in this frame and the counters.
///
/// One value instead of a dozen separate ones, so that handing it from the camera's thread
/// to the windows is one assignment, and "did anything change?" is one comparison.
struct LiveState: Equatable {
    var frameSize = CGSize(width: 1920, height: 1080)
    /// The squares being read, in frame pixels.
    var eyeRects: [CGRect] = []
    var faceFound = false
    /// The model's answer for this frame (the eyes combined), nil when no eye was read.
    var probability: Double?
    var eyesClosed = false
    var counters = BlinkStats.Snapshot()

    /// The same state once the camera is switched off: nothing in view, no rate, the
    /// counts kept.
    var withCameraOff: LiveState {
        var state = LiveState()
        state.frameSize = frameSize
        state.counters = counters
        state.counters.ratePerMinute = nil
        return state
    }
}

/// What the camera thread tells the rest of the app.
struct MonitorUpdate {
    /// The frame's time, on the camera's clock.
    var time = 0.0
    var live = LiveState()
    var preview: CGImage?
    var event: BlinkDetector.Event?

    /// A minute of the clock that just ended (see MinuteAggregator).
    var completedMinute: MinuteRecord?
    /// The minute being filled.
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
///   - Frames get only the work they need: `FrameSchedule` (inside the reader) searches
///     for the eyes every other frame, and looks at one frame in six when nobody is there.
///   - The rest of the app is only told what it needs. With no window open, an update is
///     sent when something changes (a blink, a face, a minute) and once a second -
///     not 30 times a second.
final class MonitorPipeline: @unchecked Sendable {

    /// Called on the camera queue. Not every frame: see `shouldSend`.
    var onUpdate: ((MonitorUpdate) -> Void)?

    /// What the main thread asks of the camera thread, taken in at the start of each frame.
    private struct Requests {
        var reset = false
        var liveView = false
        var capture: CaptureWriter?
        var tick = false
    }

    private let requests = Locked(Requests())
    private let reader: EyeReader
    private var detector = BlinkDetector()
    private var stats = BlinkStats()
    private var minutes = MinuteAggregator()
    private var recentTimings = StageTimings()
    private var minuteTimings = StageTimings()

    private var frameIndex = 0
    private var lastSent = MonitorUpdate()
    private var lastTimingsAt = 0.0
    private var lastMinuteTimingsAt = 0.0

    init(classifier: EyeClassifier) {
        reader = EyeReader(classifier: classifier)
    }

    // MARK: - Requests from the main thread

    /// The live counters start again from zero at the next frame. The history is not touched.
    func requestReset() {
        requests.withLock { $0.reset = true }
    }

    /// A window is showing the camera and the curve: prepare the picture, send every frame.
    func setLiveView(_ on: Bool) {
        requests.withLock { $0.liveView = on }
    }

    /// Starts (a writer) or stops (nil) recording every frame for later study.
    func setCapture(_ writer: CaptureWriter?) {
        requests.withLock {
            $0.capture = writer
            $0.tick = false
        }
    }

    /// A cue sound was just played: the next frame is marked in the capture.
    func markTick() {
        requests.withLock { $0.tick = true }
    }

    // MARK: - Every frame

    func process(_ pixelBuffer: CVPixelBuffer, time: Double) {
        frameIndex += 1
        let clock = StageTimings.now()
        recentTimings.frameDelivered(at: clock)
        minuteTimings.frameDelivered(at: clock)

        // Take this frame's requests; the one-shot ones (reset, tick) are consumed.
        let asked = requests.withLock { requests in
            defer {
                requests.reset = false
                requests.tick = false
            }
            return requests
        }
        if asked.reset {
            detector.reset()
            stats = BlinkStats()
        }

        var update = MonitorUpdate()
        update.time = time
        update.live.frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        // A capture gets every frame read in full; otherwise the reader's schedule
        // decides (and returns nothing for a frame it skips).
        var reading = FrameReading()
        do {
            if let read = try reader.read(pixelBuffer, everyFrame: asked.capture != nil) {
                reading = read.reading
                recentTimings.record(read.cost)
                minuteTimings.record(read.cost)
            }
        } catch {
            update.error = "\(error)"
            Log.pipeline.error("Frame not read: \(String(describing: error), privacy: .public)")
        }
        update.live.faceFound = reading.faceFound
        update.live.eyeRects = reading.eyeRects
        update.live.probability = reading.closed

        let watched = stats.frame(time: time, eyesRead: reading.closed != nil)
        var newBlinks = 0
        if let event = detector.update(time: time, closed: reading.closed) {
            stats.record(event)
            update.event = event
            if case .blink = event { newBlinks = 1 }
        }
        if case .closed = detector.state { update.live.eyesClosed = true }
        update.live.counters = stats.snapshot(now: time)

        // The history is kept by the clock on the wall, not the camera's own clock:
        // "at 10:15 you blinked 11 times" is what will be read later.
        update.completedMinute = minutes.add(at: Date(), observedSeconds: watched, blinks: newBlinks)
        update.currentMinute = minutes.current

        asked.capture?.write(frame: frameIndex, time: time, reading: reading,
                             state: detector.state, event: update.event, tick: asked.tick)

        if clock - lastTimingsAt >= 2 {
            update.timings = recentTimings.takeSummary(at: clock)
            lastTimingsAt = clock
        }
        if clock - lastMinuteTimingsAt >= 60 {
            update.minuteTimings = minuteTimings.takeSummary(at: clock)
            lastMinuteTimingsAt = clock
        }

        if asked.liveView && frameIndex % 2 == 0 {
            update.preview = reader.preview(pixelBuffer, maxWidth: 640)
        }
        if shouldSend(update, live: asked.liveView) {
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
        if update.live.faceFound != lastSent.live.faceFound { return true }
        return update.live.counters.ratePerMinute?.rounded() != lastSent.live.counters.ratePerMinute?.rounded()
    }
}
