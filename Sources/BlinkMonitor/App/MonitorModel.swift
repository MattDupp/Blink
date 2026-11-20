import SwiftUI
import AppKit
import Combine
import BlinkCore
import BlinkUI

/// One point of the live curve: the model's answer at one moment.
struct TraceSample: Equatable {
    let time: Double
    let probability: Double
}

/// The last seconds of the model's answers, with the blinks counted in them: what the
/// Live View window draws.
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
        var pause: PauseState = .running
        var live = LiveState()
        var curve = Curve()
        var timings: StageTimings.Summary?
        /// Shown in place of the camera picture.
        var cameraNote: String?
        var screenMinutes = 0
        var blinkBreak: BlinkBreak?
        var cameraSilent = false
    }

    // MARK: Facts

    @Published private(set) var lifecycle: Lifecycle = .starting
    /// You chose Pause: the camera is off until the pause ends, or until you choose Resume.
    @Published private(set) var pause: PauseState = .running
    /// The screen sleeps or the session is locked: the camera is off until it wakes.
    @Published private(set) var asleep = false
    /// The camera is meant to be on, and no picture has arrived for a while.
    @Published private(set) var cameraSilent = false
    @Published private(set) var live = LiveState()
    @Published private(set) var preview: CGImage?
    @Published private(set) var curve = Curve()
    @Published private(set) var timings: StageTimings.Summary?
    @Published private(set) var problem: String?

    /// A short sound at every counted blink (while the Live View window is open).
    @Published var soundOn = true

    /// Fires at every counted blink: the menu-bar eye blinks back.
    let blinked = PassthroughSubject<Void, Never>()

    // MARK: Parts

    let preferences: Preferences
    let history: HistoryController
    let reminders: ReminderController
    let blinkBreak: BlinkBreakController
    let loginItem: LoginItem
    let captures = CaptureController()

    /// No picture for this long, with the camera meant to be on, is said in the windows.
    static let silenceSeconds = 5.0

    private let camera = CameraCapture()
    /// Set in the demo: made-up eyes instead of the camera and the model.
    private let demoCamera: DemoCamera?
    private var source: FrameSource { demoCamera ?? camera }
    private var pipeline: MonitorPipeline?
    private var lastFrame: Date?
    private var watchdog: Timer?
    private var paceOfDemo: AnyCancellable?
    private let performanceLog = PerformanceLog()
    private let blinkSound = NSSound(named: "Pop")
    private var liveViewOpen = false
    private let cameraNoteOverride: String?
    private var resumeTimer: Timer?

    /// `demo`: run on made-up eyes, without the camera or the model (see `DemoCamera`).
    init(preferences: Preferences, history: HistoryController? = nil, initial: InitialState? = nil, demo: Bool = false) {
        self.preferences = preferences
        self.history = history ?? HistoryController()
        reminders = ReminderController(preferences: preferences, screenMinutes: initial?.screenMinutes ?? 0)
        blinkBreak = BlinkBreakController(exercise: initial?.blinkBreak)
        loginItem = LoginItem(allowed: !demo)
        demoCamera = demo ? DemoCamera() : nil
        cameraNoteOverride = initial?.cameraNote
        if let initial {
            lifecycle = initial.lifecycle
            pause = initial.pause
            live = initial.live
            curve = initial.curve
            timings = initial.timings
            cameraSilent = initial.cameraSilent
        } else {
            pause = preferences.pause.resolved(at: Date())      // a pause survives a relaunch
        }
    }

    var isDemo: Bool { demoCamera != nil }

    /// The camera in use, as macOS names it.
    var cameraName: String? { isDemo ? nil : camera.deviceName }

    // MARK: - What the windows say

    /// The situation, decided from the facts at the moment it is asked.
    func status(now: Date = Date()) -> MonitorStatus {
        MonitorStatus(lifecycle: lifecycle, pause: pause.resolved(at: now), asleep: asleep,
                      cameraSilent: cameraSilent, faceFound: live.faceFound, rate: live.counters.ratePerMinute,
                      recentLowRate: reminders.lowRate(in: history.minutes, now: now))
    }

    /// What the camera view shows while it has no picture.
    var cameraNote: String {
        if let cameraNoteOverride { return cameraNoteOverride }
        if isDemo { return "Demo: the camera is off, and the blinks are made up." }
        if lifecycle == .running && (isPaused || asleep) { return "Paused: the camera is off." }
        if lifecycle == .running && cameraSilent { return "The camera is not sending pictures." }
        return CameraNote.text(for: lifecycle, appName: "Blink Monitor")
    }

    // MARK: - Starting and stopping

    func start() async {
        guard lifecycle == .starting, pipeline == nil else { return }
        loginItem.refresh()
        if let demoCamera {
            startDemo(demoCamera)
            return
        }
        history.load()

        let classifier: EyeClassifier
        do {
            classifier = try EyeClassifier(compiledModel: Options.modelURL)
        } catch {
            fail("The eye model could not be loaded from \(Options.modelURL.path).\n"
                 + "Make it with: make train\n\(error)")
            return
        }
        let pipeline = MonitorPipeline(classifier: classifier)
        connect(pipeline)

        if Options.noCamera {
            fail("The camera is off (--no-camera). The model loaded correctly.")
            return
        }
        do {
            try await camera.start { pixelBuffer, time in pipeline.process(pixelBuffer, time: time) }
            began()
            reminders.prepare()
        } catch CameraCapture.CameraError.refused {
            lifecycle = .cameraRefused
        } catch {
            fail("\(error)")
        }
    }

    /// The demo: the same pipeline from the blink detector on, fed by made-up eyes.
    private func startDemo(_ demoCamera: DemoCamera) {
        let pipeline = MonitorPipeline()
        connect(pipeline)
        demoCamera.start { reading, time in pipeline.process(reading, time: time) }
        // During a blink break the made-up eyes do the exercise: slow, full blinks.
        paceOfDemo = blinkBreak.$exercise.sink { exercise in
            demoCamera.setPace(exercise.map { !$0.isDone } ?? false ? .exercise : .usual)
        }
        began()
    }

    private func connect(_ pipeline: MonitorPipeline) {
        pipeline.setLiveView(liveViewOpen)
        // Frames come from the camera's thread; the windows belong to the main thread.
        // `DispatchQueue.main.async` hands each result over, in the order it was produced.
        pipeline.onUpdate = { [weak self] update in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(update) }
            }
        }
        self.pipeline = pipeline
    }

    /// Frames are on their way.
    private func began(now: Date = Date()) {
        lifecycle = .running
        lastFrame = now
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCamera() }
        }
        if isPaused { setPause(pause) }     // still paused from before the relaunch: camera off again
    }

    /// Notices a camera that has stopped sending pictures, says so, and nudges it.
    ///
    /// Everything the windows show comes from frames. With no frame, nothing changed and
    /// the last number stayed on screen - with the lid closed on an external display,
    /// for hours. Called every two seconds while the camera is meant to run.
    func checkCamera(now: Date = Date()) {
        let expected = lifecycle == .running && !isPaused && !asleep
        let silent = expected && now.timeIntervalSince(lastFrame ?? now) > Self.silenceSeconds
        if silent != cameraSilent { cameraSilent = silent }
        guard silent else { return }
        if live.faceFound { live = live.withCameraOff }
        let source = self.source
        DispatchQueue.global(qos: .utility).async { source.recover() }
    }

    private func fail(_ reason: String) {
        Log.app.error("Not started: \(reason, privacy: .private)")   // the reason can hold a path
        lifecycle = .failed(reason)
    }

    var isPaused: Bool { pause != .running }

    /// Pause turns the camera off for real: its green light goes out. A timed pause ends
    /// by itself; the first version's pause had no end, and a pause you forget is a
    /// monitor that is silently off.
    func pause(for duration: PauseDuration, now: Date = Date()) {
        setPause(PauseState(duration, from: now))
    }

    func resume() {
        setPause(.running)
    }

    private func setPause(_ state: PauseState) {
        pause = state
        preferences.pause = state
        resumeTimer?.invalidate()
        resumeTimer = state.end.map { end in
            Timer.scheduledTimer(withTimeInterval: max(0, end.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
        applyCameraState()
    }

    /// The Mac's screen went to sleep, or woke up. Nobody is in front of a sleeping
    /// screen: the camera is switched off until it wakes.
    func setAsleep(_ value: Bool, now: Date = Date()) {
        asleep = value
        // A timer does not run while the Mac sleeps: a pause that ended meanwhile ends now.
        if !value && isPaused && !pause.isPaused(at: now) {
            resume()
        } else {
            applyCameraState()
        }
    }

    private func applyCameraState(now: Date = Date()) {
        guard lifecycle == .running else { return }
        let run = !isPaused && !asleep
        let source = self.source
        DispatchQueue.global(qos: .userInitiated).async {
            if run { source.resume() } else { source.stop() }
        }
        if run {
            lastFrame = now          // the camera needs a moment to wake: not "silent" yet
        } else {
            live = live.withCameraOff
            preview = nil
            if cameraSilent { cameraSilent = false }
        }
    }

    /// The Live View window shows the camera picture and the curve; only while it is
    /// open does the pipeline prepare the picture and report every frame.
    func setLiveViewOpen(_ open: Bool) {
        liveViewOpen = open
        pipeline?.setLiveView(open)
        if !open {
            preview = nil
            curve = Curve()
        }
    }

    // MARK: - Frames

    func apply(_ update: MonitorUpdate, now: Date = Date()) {
        guard !isPaused, !asleep else { return }   // a last frame can arrive after Pause
        lastFrame = now
        if cameraSilent { cameraSilent = false }
        if live != update.live { live = update.live }
        if let image = update.preview { preview = image }

        var counted: Blink?
        if case .blink(let blink) = update.event { counted = blink }
        if counted != nil { blinked.send() }
        if liveViewOpen {
            curve.add(time: update.time, probability: update.live.probability, blink: counted)
            // Silent during a capture: the ticks are the only sound to follow then.
            if counted != nil && soundOn && !captures.isCapturing {
                // A copy per blink: one NSSound cannot overlap itself.
                (blinkSound?.copy() as? NSSound)?.play()
            }
        }

        if let event = update.event { blinkBreak.record(event) }
        reminders.frame(time: update.time, faceFound: update.live.faceFound)

        if let timings = update.timings { self.timings = timings }
        if let minuteTimings = update.minuteTimings, !isDemo { performanceLog.append(minuteTimings) }
        if let error = update.error { problem = error }

        history.update(current: update.currentMinute)
        if let finished = update.completedMinute {
            history.minuteEnded(finished)
            adoptReference()
            reminders.minuteEnded(minutes: history.minutes)
        }
    }

    // MARK: - Your reference

    /// Measures your usual rate the first time enough has been recorded - and never again
    /// by itself (see `Baseline`: a reference that followed you would hide a decline).
    private func adoptReference(now: Date = Date()) {
        let reference = Baseline.adopt(existing: preferences.reference, records: history.minutes, now: now)
        if reference != preferences.reference { preferences.reference = reference }
    }

    /// Erases the recorded minutes, and the reference that was measured from them.
    func eraseHistory() {
        history.erase()
        preferences.reference = nil
    }

    // MARK: - Live View window

    /// Captures save pictures: there are none in the demo.
    var canCapture: Bool { !isDemo && status().isCameraOn && !captures.isCapturing }

    func resetCounters() {
        pipeline?.requestReset()
        curve = Curve()
    }

    func startCapture(cued: Bool) {
        guard canCapture, let pipeline else { return }
        // Asked at launch to keep whole frames: those captures go to their own folder.
        captures.start(cued: cued, pipeline: pipeline, root: Options.wholeFrameRoot ?? Options.captureRoot,
                       wholeFrames: Options.wholeFrameRoot != nil)
    }
}
