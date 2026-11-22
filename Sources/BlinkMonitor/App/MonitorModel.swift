import SwiftUI
import AppKit
import Combine
import CoreVideo
import AVFoundation
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
        var modelSource = ModelSource.none
        var setupStage: MonitorStatus.SetupStage?
        var failure: StartFailure?
    }

    // MARK: Facts

    @Published private(set) var lifecycle: Lifecycle = .starting
    /// You chose Pause: the camera is off until the pause ends, or until you choose Resume.
    @Published private(set) var pause: PauseState = .running
    /// The screen sleeps or the session is locked: the camera is off until it wakes.
    @Published private(set) var asleep = false
    /// Counting rests to save energy (`EnergyPause`): on battery, or in Low Power Mode,
    /// when the user chose so. The camera is off, as during sleep.
    @Published private(set) var energyHold: EnergyPause.Reason?
    /// "Resume" was pressed during such a rest: count anyway, until the reason goes.
    private var energyOverridden = false
    /// The camera is off for a reason that is not a pause: the screen sleeps, or energy.
    private var resting: Bool { asleep || energyHold != nil }
    /// The panel's Pause tile reads Resume: paused by hand, or resting to save energy.
    var showsResume: Bool { isPaused || energyHold != nil }
    /// What ended while the Mac slept, said in the panel once (`WhileAway`).
    @Published private(set) var whileAway = WhileAway()
    /// Whether the Mac is on its battery, in Low Power Mode, in a call. Closures, so that
    /// a test can state them.
    var powerFacts: () -> (onBattery: Bool, lowPower: Bool) = { (MacState.onBattery, MacState.lowPowerMode) }
    var microphoneInUse: () -> Bool = { MacState.microphoneInUse }
    /// The camera is meant to be on, and no picture has arrived for a while.
    @Published private(set) var cameraSilent = false
    @Published private(set) var live = LiveState()
    @Published private(set) var preview: CGImage?
    @Published private(set) var curve = Curve()
    @Published private(set) var timings: StageTimings.Summary?
    @Published private(set) var problem: String?
    /// Which model reads the eyes: decided at start, and again when setup installs one or
    /// Settings deletes one.
    @Published private(set) var modelSource = ModelSource.none
    /// What the setup window is doing; nil when it is not at work. While it is, nothing is
    /// counted: the poses of a recording are not how you blink.
    @Published private(set) var setupStage: MonitorStatus.SetupStage?


    /// Fires at every counted blink: the menu-bar eye blinks back.
    let blinked = PassthroughSubject<Void, Never>()

    // MARK: Parts

    let preferences: Preferences
    let history: HistoryController
    let reminders: ReminderController
    let blinkBreak: BlinkBreakController
    let loginItem: LoginItem
    /// Why counting could not start, while `lifecycle` is `.failed`.
    @Published private(set) var failure: StartFailure?
    let routines: RoutineController
    let captures = CaptureController()
    /// Where the model trained in this app is kept.
    let modelStore: ModelStore

    /// No picture for this long, with the camera meant to be on, is said in the windows.
    static let silenceSeconds = 5.0

    /// Who the camera's frames go to.
    private enum FrameRoute {
        case nobody
        case monitor(MonitorPipeline)
        /// The setup window has borrowed the camera.
        case setup((CVPixelBuffer, Double) -> Void)
    }

    private let camera = CameraCapture()
    private let frames = Locked(FrameRoute.nobody)
    /// The camera has been started once: from then on it is resumed and stopped.
    private var cameraBuilt = false
    /// The setup window is using the camera.
    private var cameraLent = false
    /// Set in the demo: made-up eyes instead of the camera and the model.
    private let demoCamera: DemoCamera?
    private var source: FrameSource { demoCamera ?? camera }
    private var pipeline: MonitorPipeline?
    private var lastFrame: Date?
    private var watchdog: Timer?
    private var paceOfDemo: AnyCancellable?
    private var lookOfDemo: AnyCancellable?
    private var exerciseWatch: AnyCancellable?
    private let performanceLog = PerformanceLog()
    private let blinkSound = NSSound(named: "Pop")
    private var liveViewOpen = false
    private let cameraNoteOverride: String?
    private var resumeTimer: Timer?

    /// `demo`: run on made-up eyes, without the camera or the model (see `DemoCamera`).
    init(preferences: Preferences, history: HistoryController? = nil, initial: InitialState? = nil, demo: Bool = false,
         modelStore: ModelStore = .standard) {
        self.preferences = preferences
        self.modelStore = modelStore
        self.history = history ?? HistoryController()
        reminders = ReminderController(preferences: preferences, screenMinutes: initial?.screenMinutes ?? 0)
        blinkBreak = BlinkBreakController(exercise: initial?.blinkBreak, seconds: initial?.blinkBreak?.isDone == true ? 38 : nil)
        loginItem = LoginItem(demo: demo)
        // Made-up eyes or a made-up state: the routine record is a scratch one too.
        routines = demo || initial != nil ? .scratch(defaults: preferences.defaults) : RoutineController(defaults: preferences.defaults)
        demoCamera = demo ? DemoCamera() : nil
        cameraNoteOverride = initial?.cameraNote
        if let initial {
            lifecycle = initial.lifecycle
            pause = initial.pause
            live = initial.live
            curve = initial.curve
            timings = initial.timings
            cameraSilent = initial.cameraSilent
            modelSource = initial.modelSource
            setupStage = initial.setupStage
            failure = initial.failure
        } else {
            pause = preferences.pause.resolved(at: Date())      // a pause survives a relaunch
        }
        routines.connect(to: self)
        blinkBreak.onDone = { [weak self] in self?.reminders.blinkBreakDone() }
        // The exercise is left out of the count for as long as it runs (`MonitorPipeline.setExercise`).
        exerciseWatch = blinkBreak.$exercise.sink { [weak self] exercise in
            self?.pipeline?.setExercise(exercise.map { !$0.isDone } ?? false)
        }
        routines.session.onEndedLate = { [weak self] session in
            guard let self else { return }
            let title = self.routines.routines.first { $0.id == session.routine }?.title ?? "a routine"
            self.whileAway.timersEnded.append(title)
        }
        reminders.busy = { [weak self] in
            guard let self else { return .free }
            return BannerGate.Busy(lookAwayBreak: self.reminders.breaks.current != nil, blinkBreak: self.blinkBreak.exercise != nil,
                                   timer: self.routines.session.session != nil, setup: self.setupStage != nil,
                                   call: self.preferences.quietDuringCalls && self.microphoneInUse())
        }
    }

    var isDemo: Bool { demoCamera != nil }

    /// The camera in use, as macOS names it.
    var cameraName: String? { isDemo ? nil : camera.deviceName }
    /// Automatic moved to this camera because the other sent no picture. Said in the
    /// panel until a camera is chosen: the model was trained on another one.
    @Published private(set) var cameraMovedTo: String?
    /// The cameras tried during the silence in progress (`CameraChoice.fallback`).
    private var camerasTried: Set<String> = []
    /// The cameras this Mac offers. A closure, so that a test can state them.
    var cameraOptions: () -> [CameraOption] = { CameraCapture.options() }
    /// Whether this Mac has a lid (stated in the tests and the screenshots).
    var macHasLid: () -> Bool = { MacState.hasLid }
    /// Where the camera in use sits, for the sentences that would otherwise speak of a
    /// lid on a Mac that has none. The demo is drawn as a portable Mac.
    var cameraPlace: CameraPlace {
        guard !isDemo else { return .lid }
        let options = cameraOptions()
        let inUse = options.first { $0.id == camera.deviceID } ?? CameraChoice.pick(from: options, wanted: preferences.cameraID)
        return CameraPlace(builtIn: inUse?.builtIn, macHasLid: macHasLid())
    }

    /// The Camera row of Settings and of the setup: `id` nil is Automatic.
    func setCamera(_ id: String?) {
        guard !isDemo else { return }
        preferences.cameraID = id
        camera.wantedCamera = id
        cameraMovedTo = nil
        camerasTried = []
        guard cameraBuilt, let picked = CameraChoice.pick(from: cameraOptions(), wanted: id) else { return }
        let camera = self.camera
        lastFrame = Date()          // the new camera needs a moment: not "silent" yet
        DispatchQueue.global(qos: .userInitiated).async { camera.use(camera: picked.id) }
    }

    // MARK: - What the windows say

    /// The situation, decided from the facts at the moment it is asked.
    func status(now: Date = Date()) -> MonitorStatus {
        MonitorStatus(lifecycle: lifecycle, setup: setupStage, pause: pause.resolved(at: now), asleep: resting,
                      cameraSilent: cameraSilent, faceFound: live.faceFound, rate: live.counters.ratePerMinute,
                      recentLowRate: reminders.lowRate(in: history.minutes, now: now))
    }

    /// What the camera view shows while it has no picture.
    var cameraNote: String {
        if let cameraNoteOverride { return cameraNoteOverride }
        if isDemo { return "Demo: the camera is off, and the blinks are made up." }
        if setupStage != nil { return "Setup is at work: nothing is counted meanwhile." }
        if lifecycle == .running && (isPaused || resting) { return "Paused: the camera is off." }
        if lifecycle == .running && cameraSilent { return CameraNote.silent }
        return CameraNote.text(for: lifecycle, appName: "Blink Monitor")
    }

    // MARK: - Starting and stopping

    func start() async {
        guard lifecycle == .starting, pipeline == nil else { return }
        loginItem.refresh()
        routines.start()
        if let demoCamera {
            startDemo(demoCamera)
            return
        }
        history.load()
        await startCounting()
    }

    /// Loads the model there is and starts counting with it. With none, the app waits
    /// for its setup (`Lifecycle.needsSetup`), the camera off.
    private func startCounting() async {
        modelSource = ModelSource.resolve(store: modelStore)
        let judge: EyeJudging
        do {
            guard let loaded = try modelSource.judge(store: modelStore) else {
                Log.app.notice("No model of the eyes yet: waiting for setup")
                lifecycle = .needsSetup
                return
            }
            judge = loaded
        } catch {
            var trainedHere = false
            if case .trainedHere = modelSource { trainedHere = true }
            fail(.model(trainedHere: trainedHere), detail: "The eye model could not be loaded.\n\(modelSource.remedy)\n\(error)")
            return
        }
        let pipeline = MonitorPipeline(classifier: judge, strategy: Options.eyeSearch)
        connect(pipeline)
        if !cameraLent { frames.withLock { $0 = .monitor(pipeline) } }

        if Options.noCamera {
            fail(.cameraLeftOff, detail: "The camera is off (--no-camera). The model loaded correctly.")
            return
        }
        do {
            try await startCamera()
            began()
            reminders.prepare()
        } catch CameraCapture.CameraError.refused {
            lifecycle = .cameraRefused
        } catch CameraCapture.CameraError.noCamera {
            fail(.noCamera, detail: "No camera was found")
        } catch {
            fail(.camera, detail: "\(error)")
        }
    }

    /// "Try Again" and "Check Again", in the panel: starts once more after a failure or a
    /// refusal. Before this, both were final until the app was quit, and nothing said so.
    func tryAgain() async {
        guard !isDemo else { return }
        switch lifecycle {
        case .failed, .cameraRefused: break
        case .starting, .needsSetup, .running: return
        }
        failure = nil
        lifecycle = .starting
        await startCounting()
    }

    /// The app came forward, or its panel opened. Someone who was refused the camera has
    /// often just been to System Settings to allow it: look, instead of waiting for a quit.
    func comeForward() {
        reminders.rereadNotifications()
        guard lifecycle == .cameraRefused, !isDemo,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        Task { await tryAgain() }
    }

    /// Starts the camera the first time (macOS asks for it then), and resumes it afterwards.
    /// Its frames go to whoever `frames` names at that moment.
    private func startCamera() async throws {
        guard !cameraBuilt else {
            let camera = self.camera
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    camera.resume()
                    continuation.resume()
                }
            }
            return
        }
        let frames = self.frames
        camera.wantedCamera = preferences.cameraID
        try await camera.start { pixelBuffer, time in
            switch frames.withLock({ $0 }) {
            case .nobody: break
            case .monitor(let pipeline): pipeline.process(pixelBuffer, time: time)
            case .setup(let handler): handler(pixelBuffer, time)
            }
        }
        cameraBuilt = true
    }

    // MARK: - Setup

    /// The setup window goes to work on something that needs no camera (training, or
    /// painted eyes): the camera is switched off. Nothing is counted until `leaveSetup`.
    func enterSetup(_ stage: MonitorStatus.SetupStage) {
        reminders.breaks.notObserved()      // the setup's time is not time at the screen, nor a break
        setupStage = stage
        live = live.withCameraOff
        preview = nil
        cameraLent = false
        if !isDemo { frames.withLock { $0 = .nobody } }
        applyCameraState()
    }

    /// The setup window borrows the camera: every frame is handed to it. macOS asks for
    /// the camera the first time; a refusal is thrown as `CameraCapture.CameraError.refused`.
    /// Nothing is counted until `leaveSetup`.
    func enterSetup(_ stage: MonitorStatus.SetupStage, frames handler: @escaping (CVPixelBuffer, Double) -> Void) async throws {
        if Options.noCamera {
            throw CameraCapture.CameraError.cannotConfigure("it was left off when the app was started")
        }
        reminders.breaks.notObserved()
        setupStage = stage
        live = live.withCameraOff
        preview = nil
        frames.withLock { $0 = .setup(handler) }
        cameraLent = true
        try await startCamera()
        applyCameraState()
    }

    /// The setup window is done with the camera, or was closed: counting goes on if there
    /// is a model, and the camera goes off if there is none.
    func leaveSetup() {
        guard setupStage != nil || cameraLent else { return }
        setupStage = nil
        cameraLent = false
        if !isDemo { frames.withLock { [pipeline] in $0 = pipeline.map { .monitor($0) } ?? .nobody } }
        applyCameraState()
    }

    /// The models on disk have changed: setup installed one, or Settings deleted one.
    /// Whatever is there now is used from the next frame on, without a restart.
    func modelChanged() async {
        guard !isDemo else { return }
        let source = ModelSource.resolve(store: modelStore)
        switch lifecycle {
        case .needsSetup:
            // The first model: this is where counting begins.
            lifecycle = .starting
            await startCounting()
        case .running:
            modelSource = source
            guard let judge = try? source.judge(store: modelStore) else {
                stopCounting()
                return
            }
            pipeline?.setJudge(judge)
        case .starting, .cameraRefused, .failed:
            modelSource = source
        }
    }

    /// No model is left: back to waiting for setup, the camera off.
    private func stopCounting() {
        watchdog?.invalidate()
        watchdog = nil
        pipeline = nil
        lifecycle = .needsSetup
        live = LiveState()
        preview = nil
        curve = Curve()
        if cameraSilent { cameraSilent = false }
        if !cameraLent {
            frames.withLock { $0 = .nobody }
            let camera = self.camera
            DispatchQueue.global(qos: .userInitiated).async { camera.stop() }
        }
    }

    /// Stops everything, before the app replaces this model by another (entering or
    /// leaving the demo from the setup window).
    func shutDown() {
        watchdog?.invalidate()
        resumeTimer?.invalidate()
        paceOfDemo = nil
        frames.withLock { $0 = .nobody }
        let source = self.source
        let built = cameraBuilt || isDemo
        if built { DispatchQueue.global(qos: .userInitiated).async { source.stop() } }
    }

    /// Deletes what setup made: the model trained here and, unless their folder was named
    /// at launch (a developer's own data), the recordings it learned from. For good.
    /// `captures`: the app's own captures folder (what Live View's record buttons saved,
    /// when it still showed them to everyone): pictures of eyes too, so it goes as well.
    func deleteModelAndRecordings(sessions root: URL, own: Bool, captures: URL? = nil) async throws {
        try modelStore.delete()
        if own, FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        if let captures, FileManager.default.fileExists(atPath: captures.path) { try FileManager.default.removeItem(at: captures) }
        await modelChanged()
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
        // During a look-away break the made-up person looks away: no face in view.
        lookOfDemo = reminders.breaks.$current.sink { current in demoCamera.setAway(current != nil) }
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
        checkEnergy()
        let expected = lifecycle == .running && !isPaused && !resting && setupStage == nil
        let silent = expected && now.timeIntervalSince(lastFrame ?? now) > Self.silenceSeconds
        if silent != cameraSilent { cameraSilent = silent }
        guard silent else {
            if !camerasTried.isEmpty { camerasTried = [] }      // pictures again: the next silence starts afresh
            return
        }
        if live.faceFound { live = live.withCameraOff }
        // AUTOMATIC: ten seconds without a picture (a closed lid, docked) and the app
        // tries the next camera, once round. A camera the user chose is never left.
        let options = isDemo ? [] : cameraOptions()
        // (Before the camera has said which one it is, it is the one Automatic starts with.)
        let current = camera.deviceID ?? CameraChoice.pick(from: options, wanted: nil)?.id
        if let next = CameraChoice.fallback(from: options, current: current, wanted: preferences.cameraID,
                                            silentSeconds: now.timeIntervalSince(lastFrame ?? now), tried: camerasTried) {
            if let current { camerasTried.insert(current) }
            camerasTried.insert(next.id)
            cameraMovedTo = next.name
            lastFrame = now
            let camera = self.camera
            DispatchQueue.global(qos: .userInitiated).async { camera.use(camera: next.id) }
            return
        }
        let source = self.source
        DispatchQueue.global(qos: .utility).async { source.recover() }
    }

    /// The panel gets a sentence for a person (`StartFailure`); what the system said
    /// goes to the log.
    private func fail(_ failure: StartFailure, detail: String) {
        Log.app.error("Not started: \(detail, privacy: .private)")   // the detail can hold a path
        self.failure = failure
        lifecycle = .failed(failure.sentence)
    }

    var isPaused: Bool { pause != .running }

    /// Pause turns the camera off for real: its green light goes out. A timed pause ends
    /// by itself; the first version's pause had no end, and a pause you forget is a
    /// monitor that is silently off.
    func pause(for duration: PauseDuration, now: Date = Date()) {
        setPause(PauseState(duration, from: now))
    }

    /// A pause until a moment of the caller's choosing: a routine's timer pauses the
    /// camera for exactly its own length.
    func pause(until end: Date) {
        setPause(.paused(until: end))
    }

    func resume() {
        // Pressed during a rest to save energy: count anyway, until the reason goes.
        if energyHold != nil {
            energyOverridden = true
            energyHold = nil
        }
        setPause(.running)
    }

    /// Looks at the power: counting rests on battery or in Low Power Mode when the user
    /// chose so, and comes back by itself. Asked every two seconds with the camera's check.
    func checkEnergy() {
        guard !isDemo else { return }
        let facts = powerFacts()
        let reason = EnergyPause.reason(onBattery: facts.onBattery, lowPower: facts.lowPower,
                                        pauseOnBattery: preferences.pauseOnBattery, pauseInLowPower: preferences.pauseInLowPower)
        if reason == nil { energyOverridden = false }
        let hold = energyOverridden ? nil : reason
        guard hold != energyHold else { return }
        energyHold = hold
        if hold != nil { reminders.breaks.notObserved() }      // time the app chose not to look at
        applyCameraState()
    }

    /// The panel was looked at: what ended during sleep has been said.
    func seenWhileAway() {
        if !whileAway.isEmpty { whileAway = WhileAway() }
    }

    private func setPause(_ state: PauseState) {
        // Paused by hand: that time is not looked at, so it is no break (`BreakSchedule`),
        // and a blink banner on screen is about a rate nobody is measuring any more.
        if state != .running {
            reminders.breaks.notObserved()
            reminders.stoppedLooking()
        }
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
        if value { reminders.stoppedLooking() }
        // A timer does not run while the Mac sleeps: a pause that ended meanwhile ends now.
        if !value && isPaused && !pause.isPaused(at: now) {
            whileAway.pauseEnded = true         // said in the panel, once: it ended with nobody there
            resume()
        } else {
            applyCameraState()
        }
    }

    private func applyCameraState(now: Date = Date()) {
        // Before the camera has ever been started there is nothing to switch.
        guard isDemo ? lifecycle == .running : cameraBuilt else { return }
        // On for the setup window when it borrowed it; else on while counting.
        let counting = lifecycle == .running && !isPaused && setupStage == nil
        // (The setup may borrow the camera whatever the energy rule says: it was asked for.)
        let run = !asleep && (cameraLent || (counting && energyHold == nil))
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
        guard !isPaused, !resting, setupStage == nil else { return }   // a last frame can arrive after Pause
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
            if counted != nil && preferences.liveViewSound && !captures.isCapturing {
                // A copy per blink: one NSSound cannot overlap itself.
                (blinkSound?.copy() as? NSSound)?.play()
            }
        }

        if let event = update.event { blinkBreak.record(event) }
        reminders.frame(faceFound: update.live.faceFound, now: now)

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
    /// "Reset to Defaults" in Settings: the choices only (`Preferences.resetChoices`), and
    /// the camera is told that it is Automatic again.
    func resetChoices() {
        preferences.resetChoices()
        setCamera(nil)
    }

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
        guard Options.developerTools, canCapture, let pipeline else { return }
        // Asked at launch to keep whole frames: those captures go to their own folder.
        captures.start(cued: cued, pipeline: pipeline, root: Options.wholeFrameRoot ?? Options.captureRoot,
                       wholeFrames: Options.wholeFrameRoot != nil)
    }
}
