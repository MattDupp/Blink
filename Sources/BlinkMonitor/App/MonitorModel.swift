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
@dynamicMemberLookup
final class MonitorModel: ObservableObject {

    /// THE MODEL'S FACTS, as one value. The windows read them through the model
    /// (`model.live`: see the subscript below).
    struct Facts {
        var lifecycle: Lifecycle = .starting
        /// You chose Pause: the camera is off until the pause ends, or until you choose Resume.
        var pause: PauseState = .running
        /// The screen sleeps or the session is locked: the camera is off until it wakes.
        var asleep = false
        /// Counting rests to save energy (`EnergyPause`): on battery, or in Low Power Mode,
        /// when the user chose so. The camera is off, as during sleep.
        var energyHold: EnergyPause.Reason?
        /// What ended while the Mac slept, said in the panel once (`WhileAway`).
        var whileAway = WhileAway()
        /// The camera is meant to be on, and no picture has arrived for a while.
        var cameraSilent = false
        var live = LiveState()
        var preview: CGImage?
        var curve = Curve()
        var timings: StageTimings.Summary?
        var problem: String?
        /// Which model reads the eyes: decided at start, and again when setup installs one or
        /// Settings deletes one.
        var modelSource = ModelSource.none
        /// What the setup window is doing; nil when it is not at work. While it is, nothing is
        /// counted: the poses of a recording are not how you blink.
        var setupStage: MonitorStatus.SetupStage?
        /// Why counting could not start, while `lifecycle` is `.failed`.
        var failure: StartFailure?
        /// Automatic moved to this camera because the other sent no picture. Said in the
        /// panel until a camera is chosen: the model was trained on another one.
        var cameraMovedTo: String?
    }

    /// What a model can be started with, instead of the camera: the screenshots build
    /// their screens from one of these (see Snapshots.swift). Its facts are read and
    /// written by name (`initial.live`); the facts start where a window that runs would.
    @dynamicMemberLookup
    struct InitialState {
        var facts = Facts(lifecycle: .running)
        /// Shown in place of the camera picture.
        var cameraNote: String?
        var screenMinutes = 0
        var blinkBreak: BlinkBreak?

        subscript<Value>(dynamicMember path: WritableKeyPath<Facts, Value>) -> Value {
            get { facts[keyPath: path] }
            set { facts[keyPath: path] = newValue }
        }
    }

    // MARK: Facts

    @Published private(set) var facts = Facts()

    /// `model.live` reads `model.facts.live`: the windows and the tests read the facts as before.
    subscript<Value>(dynamicMember path: KeyPath<Facts, Value>) -> Value { facts[keyPath: path] }
    /// (Named, because `pause(for:)` and `pause(until:)` share its name.)
    /// You chose Pause: the camera is off until the pause ends, or until you choose Resume.
    var pause: PauseState { facts.pause }

    /// "Resume" was pressed during such a rest: count anyway, until the reason goes.
    private var energyOverridden = false
    /// The camera is off for a reason that is not a pause: the screen sleeps, or energy.
    private var resting: Bool { facts.asleep || facts.energyHold != nil }
    /// The panel's Pause tile reads Resume: paused by hand, or resting to save energy.
    var showsResume: Bool { isPaused || facts.energyHold != nil }
    /// Whether the Mac is on its battery, in Low Power Mode, in a call. Closures, so that
    /// a test can state them.
    var powerFacts: () -> (onBattery: Bool, lowPower: Bool) = { (MacState.onBattery, MacState.lowPowerMode) }
    var microphoneInUse: () -> Bool = { MacState.microphoneInUse }


    /// Fires at every counted blink: the menu-bar eye blinks back.
    let blinked = PassthroughSubject<Void, Never>()

    // MARK: Parts

    let preferences: Preferences
    let history: HistoryController
    let reminders: ReminderController
    let blinkBreak: BlinkBreakController
    let loginItem: LoginItem
    let routines: RoutineController
    let captures = CaptureController()
    /// The break log: what was taken, finished and shown.
    let care: CareController
    /// The optional evening question and its notes.
    let eyeNotes: EyeNoteController
    /// The optional shortcut for a blink break. It registers nothing until the app
    /// delegate starts it.
    private(set) lazy var shortcut = ShortcutController(preferences: preferences)
    /// Where the model trained in this app is kept.
    let modelStore: ModelStore
    /// Where all of this model's files are: the user's own, or a scratch folder (`DataPlace`).
    let place: DataPlace

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
    private var effortWatch: AnyCancellable?
    private let performanceLog = PerformanceLog()
    private let blinkSound = NSSound(named: "Pop")
    private var liveViewOpen = false
    private let cameraNoteOverride: String?
    private var resumeTimer: Timer?

    /// `place`: where its files are. A scratch folder unless the user's own are asked for
    /// (`DataPlace`). `history`: minutes already known (the screenshots, the demo).
    /// `demo`: run on made-up eyes, without the camera or the model (see `DemoCamera`).
    init(preferences: Preferences, place: DataPlace = .scratch(), history: HistoryController? = nil,
         initial: InitialState? = nil, demo: Bool = false) {
        self.preferences = preferences
        self.place = place
        modelStore = place.models
        self.history = history ?? HistoryController(store: place.history)
        reminders = ReminderController(preferences: preferences, screenMinutes: initial?.screenMinutes ?? 0)
        blinkBreak = BlinkBreakController(exercise: initial?.blinkBreak, seconds: initial?.blinkBreak?.isDone == true ? 38 : nil)
        loginItem = LoginItem(demo: demo)
        routines = RoutineController(defaults: preferences.defaults, store: place.routines)
        care = CareController(store: place.care)
        eyeNotes = EyeNoteController(preferences: preferences, store: place.eyeNotes)
        demoCamera = demo ? DemoCamera() : nil
        cameraNoteOverride = initial?.cameraNote
        if let initial {
            facts = initial.facts
        } else {
            facts.pause = preferences.pause.resolved(at: Date())      // a pause survives a relaunch
        }
        routines.connect(to: self)
        blinkBreak.onDone = { [weak self] in
            self?.reminders.blinkBreakDone()
            self?.care.record(.blinkBreak)
        }
        eyeNotes.connect(to: reminders.notifier)
        eyeNotes.turns = reminders.turns
        reminders.onBlinkReminder = { [weak self] now in self?.care.record(.blinkReminder, now: now) }
        reminders.breaks.onOutcome = { [weak self] outcome, now in self?.care.record(CareEvent(outcome, at: now)) }
        // The exercise is left out of the count for as long as it runs (`MonitorPipeline.setExercise`).
        exerciseWatch = blinkBreak.$exercise.sink { [weak self] exercise in
            self?.pipeline?.setExercise(exercise.map { !$0.isDone } ?? false)
        }
        // The effort chosen in Settings reaches the camera's thread at its next frame.
        effortWatch = preferences.$effort.dropFirst().sink { [weak self] effort in
            self?.pipeline?.setEffort(effort)
        }
        routines.session.onEndedLate = { [weak self] session in
            guard let self else { return }
            let title = self.routines.routines.first { $0.id == session.routine }?.title ?? "a routine"
            self.facts.whileAway.timersEnded.append(title)
        }
        reminders.busy = { [weak self] in
            guard let self else { return .free }
            return BannerGate.Busy(lookAwayBreak: self.reminders.breaks.current != nil, blinkBreak: self.blinkBreak.exercise != nil,
                                   timer: self.routines.session.session != nil, setup: self.facts.setupStage != nil,
                                   call: self.preferences.quietDuringCalls && self.microphoneInUse())
        }
    }

    var isDemo: Bool { demoCamera != nil }

    /// The camera in use, as macOS names it.
    var cameraName: String? { isDemo ? nil : camera.deviceName }
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
        facts.cameraMovedTo = nil
        camerasTried = []
        guard cameraBuilt, let picked = CameraChoice.pick(from: cameraOptions(), wanted: id) else { return }
        lastFrame = Date()          // the new camera needs a moment: not "silent" yet
        camera.use(camera: picked.id)
    }

    // MARK: - What the windows say

    /// Whether somebody is at the screen, as far as the app can tell.
    ///
    /// While the camera is read, it is the face being in view. While it is not (a pause,
    /// the camera refused, a closed lid on an external screen), the app cannot know: a
    /// screen that is awake is taken as somebody being there, so that a pause of the
    /// camera does not silence the routines.
    func someoneAtScreen(now: Date = Date()) -> Bool {
        status(now: now).isCameraOn ? facts.live.faceFound : !facts.asleep
    }


    /// The situation, decided from the facts at the moment it is asked.
    func status(now: Date = Date()) -> MonitorStatus {
        MonitorStatus(lifecycle: facts.lifecycle, setup: facts.setupStage, pause: facts.pause.resolved(at: now), asleep: resting,
                      cameraSilent: facts.cameraSilent, faceFound: facts.live.faceFound, rate: facts.live.counters.ratePerMinute,
                      recentLowRate: reminders.lowRate(in: history.minutes, now: now))
    }

    /// What the camera view shows while it has no picture.
    var cameraNote: String {
        if let cameraNoteOverride { return cameraNoteOverride }
        if isDemo { return "Demo: the camera is off, and the blinks are made up." }
        if facts.setupStage != nil { return "Setup is at work: nothing is counted meanwhile." }
        if facts.lifecycle == .running && (isPaused || resting) { return "Paused: the camera is off." }
        if facts.lifecycle == .running && facts.cameraSilent { return CameraNote.silent }
        return CameraNote.text(for: facts.lifecycle, appName: "Blink")
    }

    // MARK: - Starting and stopping

    func start() async {
        guard facts.lifecycle == .starting, pipeline == nil else { return }
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
        facts.modelSource = ModelSource.resolve(store: modelStore)
        let judge: EyeJudging
        do {
            guard let loaded = try facts.modelSource.judge(store: modelStore) else {
                Log.app.notice("No model of the eyes yet: waiting for setup")
                facts.lifecycle = .needsSetup
                return
            }
            judge = loaded
        } catch {
            fail(.model(trainedHere: facts.modelSource.isTrainedHere),
                 detail: "The eye model could not be loaded.\n\(facts.modelSource.remedy)\n\(error)")
            return
        }
        let pipeline = MonitorPipeline(classifier: judge, strategy: Options.eyeSearch, effort: preferences.effort)
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
            facts.lifecycle = .cameraRefused
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
        switch facts.lifecycle {
        case .failed, .cameraRefused: break
        case .starting, .needsSetup, .running: return
        }
        facts.failure = nil
        facts.lifecycle = .starting
        await startCounting()
    }

    /// The app came forward, or its panel opened. Someone who was refused the camera has
    /// often just been to System Settings to allow it: look, instead of waiting for a quit.
    func comeForward() {
        reminders.rereadNotifications()
        guard facts.lifecycle == .cameraRefused, !isDemo,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        Task { await tryAgain() }
    }

    /// Starts the camera the first time (macOS asks for it then), and resumes it afterwards.
    /// Its frames go to whoever `frames` names at that moment.
    private func startCamera() async throws {
        guard !cameraBuilt else { return await camera.resumeAndWait() }
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
        facts.setupStage = stage
        facts.live = facts.live.withCameraOff
        facts.preview = nil
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
        facts.setupStage = stage
        facts.live = facts.live.withCameraOff
        facts.preview = nil
        frames.withLock { $0 = .setup(handler) }
        cameraLent = true
        try await startCamera()
        applyCameraState()
    }

    /// The setup window is done with the camera, or was closed: counting goes on if there
    /// is a model, and the camera goes off if there is none.
    func leaveSetup() {
        guard facts.setupStage != nil || cameraLent else { return }
        facts.setupStage = nil
        cameraLent = false
        if !isDemo { frames.withLock { [pipeline] in $0 = pipeline.map { .monitor($0) } ?? .nobody } }
        applyCameraState()
    }

    /// The models on disk have changed: setup installed one, or Settings deleted one.
    /// Whatever is there now is used from the next frame on, without a restart.
    func modelChanged() async {
        guard !isDemo else { return }
        let source = ModelSource.resolve(store: modelStore)
        switch facts.lifecycle {
        case .needsSetup:
            // The first model: this is where counting begins.
            facts.lifecycle = .starting
            await startCounting()
        case .running:
            facts.modelSource = source
            do {
                guard let judge = try source.judge(store: modelStore) else { return stopCounting() }
                pipeline?.setJudge(judge)
            } catch {
                // A model that cannot be read is said, as at the start (`startCounting`), with
                // Try Again. It used to be taken for no model at all, without a word.
                stopCounting()
                fail(.model(trainedHere: source.isTrainedHere), detail: "The new eye model could not be loaded.\n\(source.remedy)\n\(error)")
            }
        case .starting, .cameraRefused, .failed:
            facts.modelSource = source
        }
    }

    /// No model is left: back to waiting for setup, the camera off.
    private func stopCounting() {
        watchdog?.invalidate()
        watchdog = nil
        pipeline = nil
        facts.lifecycle = .needsSetup
        facts.live = LiveState()
        facts.preview = nil
        facts.curve = Curve()
        if facts.cameraSilent { facts.cameraSilent = false }
        if !cameraLent {
            frames.withLock { $0 = .nobody }
            camera.stop()
        }
    }

    /// Stops everything, before the app replaces this model by another (entering or
    /// leaving the demo from the setup window).
    func shutDown() {
        watchdog?.invalidate()
        resumeTimer?.invalidate()
        paceOfDemo = nil
        frames.withLock { $0 = .nobody }
        if cameraBuilt || isDemo { source.stop() }
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
        facts.lifecycle = .running
        lastFrame = now
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCamera() }
        }
        if isPaused { setPause(facts.pause) }     // still paused from before the relaunch: camera off again
    }

    /// Notices a camera that has stopped sending pictures, says so, and nudges it.
    ///
    /// Everything the windows show comes from frames. With no frame, nothing changed and
    /// the last number stayed on screen - with the lid closed on an external display,
    /// for hours. Called every two seconds while the camera is meant to run.
    func checkCamera(now: Date = Date()) {
        checkEnergy()
        let expected = facts.lifecycle == .running && !isPaused && !resting && facts.setupStage == nil
        let silent = expected && now.timeIntervalSince(lastFrame ?? now) > Self.silenceSeconds
        if silent != facts.cameraSilent { facts.cameraSilent = silent }
        guard silent else {
            if !camerasTried.isEmpty { camerasTried = [] }      // pictures again: the next silence starts afresh
            return
        }
        if facts.live.faceFound { facts.live = facts.live.withCameraOff }
        // AUTOMATIC: ten seconds without a picture (a closed lid, docked) and the app
        // tries the next camera, once round. A camera the user chose is never left.
        let options = isDemo ? [] : cameraOptions()
        // (Before the camera has said which one it is, it is the one Automatic starts with.)
        let current = camera.deviceID ?? CameraChoice.pick(from: options, wanted: nil)?.id
        if let next = CameraChoice.fallback(from: options, current: current, wanted: preferences.cameraID,
                                            silentSeconds: now.timeIntervalSince(lastFrame ?? now), tried: camerasTried) {
            if let current { camerasTried.insert(current) }
            camerasTried.insert(next.id)
            facts.cameraMovedTo = next.name
            lastFrame = now
            camera.use(camera: next.id)
            return
        }
        source.recover()
    }

    /// The panel gets a sentence for a person (`StartFailure`); what the system said
    /// goes to the log.
    private func fail(_ reason: StartFailure, detail: String) {
        Log.app.error("Not started: \(detail, privacy: .private)")   // the detail can hold a path
        self.facts.failure = reason
        facts.lifecycle = .failed(reason.sentence)
    }

    var isPaused: Bool { facts.pause != .running }

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
        if facts.energyHold != nil {
            energyOverridden = true
            facts.energyHold = nil
        }
        setPause(.running)
    }

    /// Looks at the power: counting rests on battery or in Low Power Mode when the user
    /// chose so, and comes back by itself. Asked every two seconds with the camera's check.
    func checkEnergy() {
        guard !isDemo else { return }
        let power = powerFacts()
        let reason = EnergyPause.reason(onBattery: power.onBattery, lowPower: power.lowPower,
                                        pauseOnBattery: preferences.pauseOnBattery, pauseInLowPower: preferences.pauseInLowPower)
        if reason == nil { energyOverridden = false }
        let hold = energyOverridden ? nil : reason
        guard hold != facts.energyHold else { return }
        facts.energyHold = hold
        if hold != nil { reminders.breaks.notObserved() }      // time the app chose not to look at
        applyCameraState()
    }

    /// The panel was looked at: what ended during sleep has been said.
    func seenWhileAway() {
        if !facts.whileAway.isEmpty { facts.whileAway = WhileAway() }
    }

    private func setPause(_ state: PauseState) {
        // Paused by hand: that time is not looked at, so it is no break (`BreakSchedule`),
        // and a blink banner on screen is about a rate nobody is measuring any more.
        if state != .running {
            reminders.breaks.notObserved()
            reminders.stoppedLooking()
        }
        facts.pause = state
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
        facts.asleep = value
        if value { reminders.stoppedLooking() }
        // A timer does not run while the Mac sleeps: a pause that ended meanwhile ends now.
        if !value && isPaused && !facts.pause.isPaused(at: now) {
            facts.whileAway.pauseEnded = true         // said in the panel, once: it ended with nobody there
            resume()
        } else {
            applyCameraState()
        }
    }

    private func applyCameraState(now: Date = Date()) {
        // Before the camera has ever been started there is nothing to switch.
        guard isDemo ? facts.lifecycle == .running : cameraBuilt else { return }
        // On for the setup window when it borrowed it; else on while counting.
        let counting = facts.lifecycle == .running && !isPaused && facts.setupStage == nil
        // (The setup may borrow the camera whatever the energy rule says: it was asked for.)
        let run = !facts.asleep && (cameraLent || (counting && facts.energyHold == nil))
        // Neither call blocks: each camera does its work on a queue of its own, in order.
        if run { source.resume() } else { source.stop() }
        if run {
            lastFrame = now          // the camera needs a moment to wake: not "silent" yet
        } else {
            facts.live = facts.live.withCameraOff
            facts.preview = nil
            if facts.cameraSilent { facts.cameraSilent = false }
        }
    }

    /// The Live View window shows the camera picture and the curve; only while it is
    /// open does the pipeline prepare the picture and report every frame.
    func setLiveViewOpen(_ open: Bool) {
        liveViewOpen = open
        pipeline?.setLiveView(open)
        if !open {
            facts.preview = nil
            facts.curve = Curve()
        }
    }

    // MARK: - Frames

    func apply(_ update: MonitorUpdate, now: Date = Date()) {
        guard !isPaused, !resting, facts.setupStage == nil else { return }   // a last frame can arrive after Pause
        lastFrame = now
        if facts.cameraSilent { facts.cameraSilent = false }
        if facts.live != update.live { facts.live = update.live }
        if let image = update.preview { facts.preview = image }

        var counted: Blink?
        if case .blink(let blink) = update.event { counted = blink }
        if counted != nil { blinked.send() }
        if liveViewOpen {
            facts.curve.add(time: update.time, probability: update.live.probability, blink: counted)
            // Silent during a capture: the ticks are the only sound to follow then.
            if counted != nil && preferences.liveViewSound && !captures.isCapturing {
                // A copy per blink: one NSSound cannot overlap itself.
                (blinkSound?.copy() as? NSSound)?.play()
            }
        }

        if let event = update.event { blinkBreak.record(event) }
        reminders.frame(faceFound: update.live.faceFound, now: now)

        if let summary = update.timings { self.facts.timings = summary }
        if let minuteTimings = update.minuteTimings, !isDemo { performanceLog.append(minuteTimings) }
        if let error = update.error { facts.problem = error }

        history.update(current: update.currentMinute)
        if let finished = update.completedMinute {
            history.minuteEnded(finished)
            adoptReference()
            reminders.minuteEnded(minutes: history.minutes)
            reminders.summaryIfDue(minutes: history.minutes)
            eyeNotes.askIfDue()
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
        facts.curve = Curve()
    }

    func startCapture(cued: Bool) {
        guard Options.developerTools, canCapture, let pipeline else { return }
        // Asked at launch to keep whole frames: those captures go to their own folder.
        captures.start(cued: cued, pipeline: pipeline, root: Options.wholeFrameRoot ?? Options.captureRoot,
                       wholeFrames: Options.wholeFrameRoot != nil)
    }
}
