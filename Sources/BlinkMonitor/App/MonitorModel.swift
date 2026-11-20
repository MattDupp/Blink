import SwiftUI
import AppKit
import BlinkCore

/// One point of the live curve: the model's answer at one moment.
struct TraceSample: Equatable {
    let time: Double
    let probability: Double
}

/// The last seconds of the model's answers, with the blinks counted in them: what the
/// diagnostics window draws.
struct Curve: Equatable {
    /// How many seconds are shown.
    static let seconds = 10.0

    /// The latest frame's time, on the camera's clock.
    var now = 0.0
    var samples: [TraceSample] = []
    var blinks: [Blink] = []

    mutating func add(time: Double, probability: Double?, blink: Blink?) {
        now = time
        if let probability { samples.append(TraceSample(time: time, probability: probability)) }
        if let blink { blinks.append(blink) }
        let oldest = time - Self.seconds - 1
        if let first = samples.first, first.time < oldest {
            samples.removeAll { $0.time < oldest }
            blinks.removeAll { $0.end < oldest }
        }
    }
}

/// The app's live state, and the place where its parts are connected: camera, pipeline,
/// history, reminders.
///
/// It stores FACTS (the lifecycle, paused or not, the pipeline's latest state). What the
/// windows say about them is derived on demand (`status`), never stored.
///
/// Main thread only; the camera thread hands its results over through `apply`.
@MainActor
final class MonitorModel: ObservableObject {

    /// What a model can be started with, instead of the camera: the screenshots build
    /// their screens from one of these (see Snapshots.swift).
    struct InitialState {
        var lifecycle: Lifecycle = .running
        var live = LiveState()
        var curve = Curve()
        var timings: StageTimings.Summary?
        /// Shown in place of the camera picture.
        var cameraNote: String?
    }

    // MARK: Facts

    @Published private(set) var lifecycle: Lifecycle = .starting
    /// You chose Pause: the camera is off until you choose Resume.
    @Published private(set) var paused = false
    /// The screen sleeps or the session is locked: the camera is off until it wakes.
    @Published private(set) var asleep = false
    @Published private(set) var live = LiveState()
    @Published private(set) var preview: CGImage?
    @Published private(set) var curve = Curve()
    @Published private(set) var timings: StageTimings.Summary?
    @Published private(set) var problem: String?

    /// A short sound at every counted blink (while the diagnostics window is open).
    @Published var soundOn = true

    // MARK: Parts

    let history: HistoryController
    let reminders: ReminderController
    let loginItem = LoginItem()
    let captures = CaptureController()

    private let camera = CameraCapture()
    private var pipeline: MonitorPipeline?
    private let performanceLog = PerformanceLog()
    private let blinkSound = NSSound(named: "Pop")
    private var diagnosticsOpen = false
    private let cameraNoteOverride: String?

    init(settings: Settings = Settings(), history: HistoryController? = nil, initial: InitialState? = nil) {
        self.history = history ?? HistoryController()
        reminders = ReminderController(settings: settings)
        cameraNoteOverride = initial?.cameraNote
        if let initial {
            lifecycle = initial.lifecycle
            live = initial.live
            curve = initial.curve
            timings = initial.timings
        }
    }

    // MARK: - What the windows say

    /// The situation, decided from the facts at the moment it is asked.
    func status(now: Date = Date()) -> MonitorStatus {
        MonitorStatus(lifecycle: lifecycle, paused: paused || asleep, faceFound: live.faceFound,
                      rate: live.counters.ratePerMinute,
                      recentLowRate: reminders.lowRate(in: history.minutes, now: now))
    }

    /// What the camera view shows while it has no picture.
    var cameraNote: String { cameraNoteOverride ?? status().cameraNote }

    // MARK: - Starting and stopping

    func start() async {
        guard lifecycle == .starting, pipeline == nil else { return }
        history.load()
        loginItem.refresh()

        let classifier: EyeClassifier
        do {
            classifier = try EyeClassifier(compiledModel: Options.modelURL)
        } catch {
            fail("The eye model could not be loaded from \(Options.modelURL.path).\n"
                 + "Make it with: make train\n\(error)")
            return
        }
        let pipeline = MonitorPipeline(classifier: classifier)
        pipeline.setLiveView(diagnosticsOpen)
        self.pipeline = pipeline

        if Options.noCamera {
            fail("The camera is off (--no-camera). The model loaded correctly.")
            return
        }
        guard await CameraCapture.requestPermission() else {
            lifecycle = .cameraRefused
            return
        }

        // Frames come from the camera's thread; the windows belong to the main thread.
        // `DispatchQueue.main.async` hands each result over, in the order it was produced.
        pipeline.onUpdate = { [weak self] update in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(update) }
            }
        }
        let camera = self.camera
        let failure: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try camera.start { pixelBuffer, time in pipeline.process(pixelBuffer, time: time) }
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: "\(error)")
                }
            }
        }
        if let failure {
            fail(failure)
            return
        }
        lifecycle = .running
        reminders.prepare()
    }

    private func fail(_ reason: String) {
        Log.app.error("Not started: \(reason, privacy: .private)")   // the reason can hold a path
        lifecycle = .failed(reason)
    }

    /// Pause turns the camera off for real: its green light goes out.
    func setPaused(_ value: Bool) {
        paused = value
        applyCameraState()
    }

    /// The Mac's screen went to sleep, or woke up. Nobody is in front of a sleeping
    /// screen: the camera is switched off until it wakes.
    func setAsleep(_ value: Bool) {
        asleep = value
        applyCameraState()
    }

    private func applyCameraState() {
        guard lifecycle == .running else { return }
        let run = !paused && !asleep
        let camera = self.camera
        DispatchQueue.global(qos: .userInitiated).async {
            if run { camera.resume() } else { camera.stop() }
        }
        if !run {
            live = live.withCameraOff
            preview = nil
        }
    }

    /// The diagnostics window shows the camera picture and the curve; only while it is
    /// open does the pipeline prepare the picture and report every frame.
    func setDiagnosticsOpen(_ open: Bool) {
        diagnosticsOpen = open
        pipeline?.setLiveView(open)
        if !open {
            preview = nil
            curve = Curve()
        }
    }

    // MARK: - Frames

    private func apply(_ update: MonitorUpdate) {
        guard !paused, !asleep else { return }   // a last frame can arrive after Pause
        if live != update.live { live = update.live }
        if let image = update.preview { preview = image }

        var counted: Blink?
        if case .blink(let blink) = update.event { counted = blink }
        if diagnosticsOpen {
            curve.add(time: update.time, probability: update.live.probability, blink: counted)
            // Silent during a capture: the ticks are the only sound to follow then.
            if counted != nil && soundOn && !captures.isCapturing {
                // A copy per blink: one NSSound cannot overlap itself.
                (blinkSound?.copy() as? NSSound)?.play()
            }
        }

        if let timings = update.timings { self.timings = timings }
        if let minuteTimings = update.minuteTimings { performanceLog.append(minuteTimings) }
        if let error = update.error { problem = error }

        history.update(current: update.currentMinute)
        if let finished = update.completedMinute {
            history.minuteEnded(finished)
            reminders.minuteEnded(minutes: history.minutes)
        }
    }

    // MARK: - Diagnostics window

    var canCapture: Bool { status().isCameraOn && !captures.isCapturing }

    func resetCounters() {
        pipeline?.requestReset()
        curve = Curve()
    }

    func startCapture(cued: Bool) {
        guard canCapture, let pipeline else { return }
        captures.start(cued: cued, pipeline: pipeline, root: Options.captureRoot)
    }
}
