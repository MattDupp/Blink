import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

/// The setup: from "this Mac has no model of your eyes" to "it counts your blinks", in
/// one window.
///
///     welcome -> camera check -> record (twice) -> train -> test -> done
///
/// WHERE YOU ARE IS READ FROM THE DISK, not remembered. The recordings and the model are
/// files; the step to open on is worked out from them (`resumeStep`). Closing the window
/// or quitting in the middle loses nothing that was finished, and there is no saved
/// "current step" to disagree with what is really there.
///
/// Like `MonitorModel`, it stores facts and is fed events by hand in the tests: frames
/// through `apply`, the trainer's words through `training(_:)`.
@MainActor
@dynamicMemberLookup
final class SetupModel: ObservableObject {

    enum Step: Int, Comparable {
        case welcome, camera, record, train, proof, done

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    /// Why the window was opened.
    enum Purpose {
        /// Go on where things stand.
        case resume
        /// The same, opened by the app itself when it starts with a setup left unfinished:
        /// a page says so first, and the camera only turns on when asked.
        case atLaunch
        /// Record one more session, then train and test again (from Settings).
        case addSession
        /// Take the test again with the model there is (from Settings).
        case test
    }

    enum CameraState: Equatable {
        case off
        /// macOS is asking for the camera.
        case asking
        case refused
        case failed(String)
        case on
    }

    enum PhaseState {
        case idle, listening, settling, recording
    }

    enum Training: Equatable {
        case waiting
        case reading(done: Int, total: Int)
        /// `secondsLeft`: measured from the passes already made; nil during the first one.
        case learning(pass: Int, of: Int, secondsLeft: Double?)
        case checking
        /// `attempts`: how many trainings have failed in a row.
        case failed(reason: String, attempts: Int)
        case done
    }

    enum Proof: Equatable {
        case ready
        case running
        case finished(ProofTest.Result)
    }

    /// Everything the setup works with that is not its own state.
    struct Parts {
        var monitor: MonitorModel
        var store: ModelStore
        var sessionsRoot: URL
        /// The sessions folder is the app's own. False when it was named at launch
        /// (`--sessions-dir`, a developer's data): then nothing in it is deleted for good.
        var ownSessions = true
        var pace = SessionPace.usual
        /// Set in the demo and in the tests: painted eyes instead of the camera.
        var painted: PaintedCamera?
        var trainingWay = TrainingJob.Way.usual
        var passes = TrainingRun.passes
    }

    /// THE SETUP'S FACTS, as one value. The windows read them through the model
    /// (`model.step`: see the subscript below). The screenshots hand a whole `Facts` to `init`
    /// instead of the disk and the camera; they used to fill a copy of each fact, field by
    /// field, which `init` then copied back one by one, and a new fact needed three edits.
    struct Facts {
        var step = Step.welcome
        /// The step that waits behind the welcome-back page. Nil: no such page.
        var welcomeBack: Step?
        var camera = CameraState.off
        /// The cameras this Mac offers, for the camera page (empty in the demo).
        var cameras: [CameraOption] = []
        /// The complete sessions on disk, oldest first.
        var sessions: [SessionSummary] = []
        /// The model trained here, when there is one.
        var info: ModelInfo?
        var hasPrevious = false
        var preview: CGImage?
        var frameSize = CGSize(width: 1920, height: 1080)
        var eyeRects: [CGRect] = []
        var faceFound = false
        /// No face for a few seconds, with the camera running.
        var faceMissing = false
        /// The camera is on and sends no picture.
        var cameraSilent = false
        var cropSide = 0
        var leftCrop: CGImage?
        var rightCrop: CGImage?
        /// The eye pictures' average brightness over the last second, 0 to 255.
        var brightness: Double?
        var sessionRunning = false
        var phaseState = PhaseState.idle
        var phaseIndex = 0
        var recordProgress = 0.0
        /// How far the window's brightness is changed, 0 to 1: the end of a closed-eye pose,
        /// shown to someone who cannot hear its sound (`PoseSignal`).
        var glow = 0.0
        var sessionOpen = 0
        var sessionClosed = 0
        /// Said after a session that was not kept.
        var sessionNote: String?
        /// Sessions wanted before training is offered.
        var targetSessions = SessionScript.sessionsBeforeTraining
        var problem: String?
        /// The poses of the last session during which the camera lost the face, even when
        /// asked a second time.
        var lostPoses: [Phase] = []
        /// The Mac's sound is muted or at zero: the voice would not be heard.
        var soundMuted = false
        var training = Training.waiting
        /// A few of your pictures as the model is shown them during this pass: altered.
        var alteredSamples: [CGImage] = []
        /// The training has said nothing for ten seconds: "Still working…".
        var trainingSilent = false
        var proof = Proof.ready
        var proofTest = ProofTest()
        /// Tests failed in a row on this model. One is often a missed tick, so the first
        /// offers the test again; the second offers one more recording.
        var failedTests = 0
        /// The model reads the eyes as closed right now (the ring shows it).
        var eyesClosed = false
        /// Stated by the screenshots instead of measured on disk.
        var statedMegabytes: Double?
        var statedPlace: String?

        /// Both eye pictures at once (the screenshots).
        var crops: [CGImage?] {
            get { [leftCrop, rightCrop] }
            set { (leftCrop, rightCrop) = (newValue.first ?? nil, newValue.dropFirst().first ?? nil) }
        }
    }

    // MARK: Facts

    @Published private(set) var facts: Facts

    /// `model.step` reads `model.facts.step`: the windows and the tests read the facts as before.
    subscript<Value>(dynamicMember path: KeyPath<Facts, Value>) -> Value { facts[keyPath: path] }

    /// The camera chosen for the app: nil is Automatic.
    var chosenCamera: String? { monitor.preferences.cameraID }

    /// The camera page's pop-up: the choice is the app's, the same as in Settings.
    func chooseCamera(_ id: String?) {
        monitor.setCamera(id)
        objectWillChange.send()
    }

    // The camera, as the window shows it.

    // Recording.
    /// Reduce Motion, as macOS has it (stated in the tests).
    var reduceMotion: () -> Bool = { Comfort.reduceMotion }

    // Training.
    private var lastTrainingWord = Date()
    private var trainingWatch: Task<Void, Never>?

    // The test.

    let parts: Parts
    var monitor: MonitorModel { parts.monitor }
    var isDemo: Bool { parts.monitor.isDemo }

    /// Eye squares smaller than the model's own 64 pixels are enlarged: detail is invented.
    static let smallestCropSide = EyeCropper.outputSize
    /// Under this average brightness (0 to 255) the camera check warns. A STARTING VALUE,
    /// not a measured limit: the four sessions this project was built on had 95, 130, 136
    /// and 161, and none was dark (measured 2026-11-20), so nothing here shows where a
    /// model starts to fail.
    static let dimBelow = 60.0
    /// No face for this long is said in the window.
    static let faceMissingAfter = 3.0

    private let pipeline: SessionPipeline
    private let speaker = Speaker()
    private let tickSound = NSSound(named: "Tink")
    private var sessionTask: Task<Void, Never>?
    private var testTask: Task<Void, Never>?
    private var cameraRequest = 0
    private var job: TrainingJob?
    private var failedTrainings = 0
    private var sampleSources: [[Float]] = []
    private var recentFaces: [Bool] = []
    private var recentLevels: [Double] = []
    private var lastFaceAt: Double?
    private var firstFrameAt: Double?
    private var lastFrame: Date?
    private var silenceTimer: Timer?
    private var isOpen = false
    /// Held while a session or the test runs: see `stayAwake`.
    private var awake: NSObjectProtocol?

    /// `facts`: where to start; the screenshots state them, the app starts from nothing.
    init(parts: Parts, facts: Facts = Facts()) {
        self.parts = parts
        self.facts = facts
        pipeline = SessionPipeline(pace: parts.pace)
        pipeline.onUpdate = { [weak self] frame in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(frame) }
            }
        }
    }

    // MARK: - Where to begin

    /// The step the facts on disk call for.
    static func resumeStep(completeSessions: Int, info: ModelInfo?, welcomed: Bool) -> Step {
        if let info { return info.isAccepted ? .done : .proof }
        return completeSessions > 0 || welcomed ? .camera : .welcome
    }

    /// Opened by the app at launch, the setup does not turn the camera on by itself: the
    /// day after leaving it, a green light with no click was the first thing seen.
    static func waitsForContinue(_ step: Step, purpose: Purpose) -> Bool {
        purpose == .atLaunch && (step == .camera || step == .record || step == .proof)
    }

    /// "Continue", on the welcome-back page.
    func continueSetup() {
        guard let next = facts.welcomeBack else { return }
        facts.welcomeBack = nil
        enter(next)
    }

    /// "Back", on the camera page: to the welcome page, where the demo is offered.
    func backToWelcome() {
        guard facts.step == .camera else { return }
        enter(.welcome)
    }

    /// The window opens.
    func open(_ purpose: Purpose = .resume) {
        guard !isOpen else { return }
        isOpen = true
        facts.welcomeBack = nil
        rescan()
        facts.problem = nil
        facts.sessionNote = nil
        failedTrainings = 0
        switch purpose {
        case .resume, .atLaunch:
            facts.targetSessions = max(SessionScript.sessionsBeforeTraining, facts.info == nil ? 0 : facts.sessions.count)
            let next = Self.resumeStep(completeSessions: facts.sessions.count, info: facts.info, welcomed: monitor.preferences.welcomed)
            if Self.waitsForContinue(next, purpose: purpose) { facts.welcomeBack = next } else { enter(next) }
        case .addSession:
            facts.targetSessions = max(SessionScript.sessionsBeforeTraining, facts.sessions.count + 1)
            enter(.camera)
        case .test:
            enter(facts.info == nil ? .camera : .proof)
        }
    }

    /// The window closes: whatever is under way stops. What was finished stays on disk.
    func close() {
        guard isOpen else { return }
        isOpen = false
        facts.welcomeBack = nil
        cameraRequest += 1
        sessionTask?.cancel()
        testTask?.cancel()
        speaker.stop()
        letSleep()
        job?.cancel()
        job = nil
        parts.store.discardStaging()
        // A model trained again but not yet tested must not leave you with nothing: the
        // one you were using comes back. The new recordings are kept; training is 20 s.
        if let installed = facts.info, !installed.isAccepted, parts.store.hasPrevious {
            try? parts.store.restorePrevious()
        }
        releaseCamera()
        monitor.leaveSetup()
    }

    private func rescan() {
        facts.sessions = SessionStore.sessions(in: parts.sessionsRoot).filter {
            SessionCheck.isComplete(pictures: $0.pictures, pace: parts.pace)
        }
        facts.info = parts.store.info()
        facts.hasPrevious = parts.store.hasPrevious
    }

    /// Where the recordings and the model are, as a person writes a path: ~/Library/...
    var place: String {
        facts.statedPlace ?? (parts.store.base.path as NSString).abbreviatingWithTildeInPath
    }

    /// The disk space of the recordings and the model, in megabytes.
    var megabytesOnDisk: Double {
        if let stated = facts.statedMegabytes { return stated }
        return Double(SessionStore.bytes(under: parts.sessionsRoot) + SessionStore.bytes(under: parts.store.folder)) / 1_000_000
    }

    // MARK: - Moving between steps

    private func enter(_ new: Step) {
        facts.step = new
        Log.app.notice("Setup: \(String(describing: new), privacy: .public)")
        switch new {
        case .welcome:
            releaseCamera()
            monitor.leaveSetup()
        case .camera:
            if !isDemo { facts.cameras = monitor.cameraOptions() }
            useCamera(for: .checkingCamera)
        case .record:
            useCamera(for: .recording)
        case .train:
            releaseCamera()
            monitor.enterSetup(.training)
        case .proof:
            facts.proof = .ready
            facts.proofTest = ProofTest()
            useCamera(for: .testing)
        case .done:
            releaseCamera()
        }
    }

    /// "Set up on my eyes", on the welcome page.
    func begin() {
        monitor.preferences.welcomed = true
        enter(.camera)
    }

    /// "Continue", on the camera page.
    func cameraLooksRight() {
        guard canLeaveCameraCheck else { return }
        enter(.record)
    }

    // MARK: - The camera

    /// Turns the camera (or the painted eyes) on for a step, and says what came of it.
    private func useCamera(for stage: MonitorStatus.SetupStage) {
        cameraRequest += 1
        let request = cameraRequest
        // The test reads the eyes with the model that was just trained.
        if stage == .testing {
            do {
                pipeline.setJudge(try parts.store.network())
            } catch {
                facts.camera = .failed("The model could not be read back from disk: \(error)")
                return
            }
        } else {
            pipeline.setJudge(nil)
        }
        resetCameraFacts()
        let pipeline = self.pipeline
        if let painted = parts.painted {
            // Painted eyes: no camera to ask for.
            monitor.enterSetup(stage)
            painted.follow(.look)
            painted.start(into: pipeline)
            facts.camera = .on
            watchForSilence()
            return
        }
        if facts.camera != .on { facts.camera = .asking }
        Task {
            do {
                try await monitor.enterSetup(stage) { pipeline.process($0, time: $1) }
                guard request == cameraRequest else { return }
                facts.camera = .on
                watchForSilence()
            } catch CameraCapture.CameraError.refused {
                guard request == cameraRequest else { return }
                facts.camera = .refused
            } catch {
                guard request == cameraRequest else { return }
                // A sentence for a person, with what to do. The error's own text goes to the log.
                Log.app.error("Setup: the camera could not be started: \(String(describing: error), privacy: .public)")
                facts.camera = .failed(Self.cameraTrouble(error))
            }
        }
    }

    private func releaseCamera() {
        cameraRequest += 1
        parts.painted?.stop()
        pipeline.setRecording(nil)
        pipeline.setJudge(nil)
        silenceTimer?.invalidate()
        silenceTimer = nil
        if facts.camera == .on || facts.camera == .asking { facts.camera = .off }
        facts.preview = nil
        resetCameraFacts()
    }

    private func resetCameraFacts() {
        facts.faceFound = false
        facts.faceMissing = false
        facts.cameraSilent = false
        facts.eyeRects = []
        recentFaces = []
        recentLevels = []
        lastFaceAt = nil
        firstFrameAt = nil
        lastFrame = nil
        facts.eyesClosed = false
    }

    /// "Check Again", after the camera was refused.
    func askForCameraAgain() {
        guard facts.step == .camera || facts.step == .record || facts.step == .proof else { return }
        enter(facts.step)
    }

    /// A face has been in view steadily: recording an empty chair teaches nothing.
    var faceSteady: Bool {
        recentFaces.count >= 15 && recentFaces.filter { $0 }.count * 5 >= recentFaces.count * 4
    }

    var eyesLargeEnough: Bool { facts.cropSide >= Self.smallestCropSide }
    var lightEnough: Bool { (facts.brightness ?? 255) >= Self.dimBelow }

    /// (The screenshots have no frames: they state `faceFound` instead.)
    var faceInView: Bool { recentFaces.isEmpty ? facts.faceFound : faceSteady }
    var canLeaveCameraCheck: Bool { facts.camera == .on && faceInView }

    /// A training is under way (for the question asked before quitting).
    var trainingUnderWay: Bool {
        guard isOpen, facts.step == .train else { return false }
        switch facts.training {
        case .done, .failed: return false
        default: return true
        }
    }

    /// Has the training said nothing for a while? Asked once a second.
    @discardableResult
    func checkTraining(now: Date = Date()) -> Bool {
        let working: Bool
        switch facts.training {
        case .done, .failed: working = false
        default: working = facts.step == .train
        }
        let silent = working && TrainingSilence.isSilent(lastWord: lastTrainingWord, now: now)
        if silent != facts.trainingSilent { facts.trainingSilent = silent }
        return working
    }

    /// Why the camera did not start, with what to try.
    static func cameraTrouble(_ error: Error) -> String {
        if case CameraCapture.CameraError.noCamera = error {
            return "No camera was found. \(CameraNote.findOne(macHasLid: MacState.hasLid)), then press Check Again."
        }
        return "Another app may be using the camera. Quit that app, then press Check Again."
    }

    private func watchForSilence() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForSilence()
                self?.checkSound()
            }
        }
        checkSound()
    }

    /// "Play the Voice": one sentence, to hear that the guide can be heard BEFORE closing
    /// your eyes. On a muted Mac a session looked like a frozen app, seen two minutes later.
    func playVoice() {
        guard !facts.sessionRunning else { return }
        speaker.stop()
        Task { await speaker.say("This is the voice that will guide you. If you can hear it, you are ready.") }
    }

    private func checkSound() {
        let muted = facts.step == .record && !facts.sessionRunning && parts.painted == nil && SoundOutput.isMuted
        if muted != facts.soundMuted { facts.soundMuted = muted }
    }

    func checkForSilence(now: Date = Date()) {
        guard facts.camera == .on else { return }
        let silent = lastFrame.map { now.timeIntervalSince($0) > MonitorModel.silenceSeconds } ?? false
        if silent != facts.cameraSilent { facts.cameraSilent = silent }
    }

    // MARK: - Frames

    func apply(_ frame: SessionFrame, now: Date = Date()) {
        guard facts.camera == .on else { return }      // a last frame can arrive after the camera was let go
        lastFrame = now
        if facts.cameraSilent { facts.cameraSilent = false }
        if let image = frame.preview { facts.preview = image }
        facts.frameSize = frame.frameSize
        if facts.eyeRects != frame.eyeRects { facts.eyeRects = frame.eyeRects }
        if facts.faceFound != frame.faceFound { facts.faceFound = frame.faceFound }

        recentFaces.append(frame.faceFound)
        if recentFaces.count > 30 { recentFaces.removeFirst() }
        if firstFrameAt == nil { firstFrameAt = frame.time }
        if frame.faceFound { lastFaceAt = frame.time }
        let missing = frame.time - (lastFaceAt ?? firstFrameAt ?? frame.time) > Self.faceMissingAfter
        if missing != facts.faceMissing { facts.faceMissing = missing }

        if frame.faceFound {
            if frame.cropSide > 0, facts.cropSide != frame.cropSide { facts.cropSide = frame.cropSide }
            facts.leftCrop = frame.leftCrop
            facts.rightCrop = frame.rightCrop
            if let level = frame.brightness {
                recentLevels.append(level)
                if recentLevels.count > 30 { recentLevels.removeFirst() }
                let average = (recentLevels.reduce(0, +) / Double(recentLevels.count)).rounded()
                if facts.brightness != average { facts.brightness = average }
            }
        }
        facts.sessionOpen += frame.savedOpen
        facts.sessionClosed += frame.savedClosed
        if let error = frame.error { facts.problem = error }

        if facts.eyesClosed != frame.eyesClosed { facts.eyesClosed = frame.eyesClosed }
        if facts.proof == .running {
            if frame.tick { facts.proofTest.tick(at: frame.time) }
            if let blink = frame.blink {
                facts.proofTest.blink(blink)
                monitor.blinked.send()             // the menu-bar eye answers too
            }
        }
    }

    // MARK: - Recording

    /// The number the next session will have, counting from 1.
    var nextSession: Int { facts.sessions.count + 1 }
    var enoughSessions: Bool { facts.sessions.count >= facts.targetSessions }
    var canStartSession: Bool { facts.step == .record && facts.camera == .on && facts.faceFound && !facts.sessionRunning }

    func startSession() {
        guard canStartSession else { return }
        facts.sessionRunning = true
        stayAwake("Recording a session of the setup")
        sessionTask = Task {
            await runSession()
            facts.sessionRunning = false
            letSleep()
        }
    }

    /// The end of a pose, shown: one soft change of the window's brightness, or with
    /// Reduce Motion a steady one that lasts until the next pose begins.
    func show(_ signal: PoseSignal) {
        switch signal {
        case .none: break
        case .steady: facts.glow = signal.strength
        case .pulse(let rise, let hold, let fall):
            withAnimation(.easeInOut(duration: rise)) { facts.glow = signal.strength }
            DispatchQueue.main.asyncAfter(deadline: .now() + rise + hold) { [weak self] in
                withAnimation(.easeInOut(duration: fall)) { self?.facts.glow = 0 }
            }
        }
    }

    func stopSession() {
        sessionTask?.cancel()
        speaker.stop()
    }

    /// Asks macOS to keep the display on. A session is two minutes with no key pressed
    /// and the eyes closed half the time: a display that sleeps turns the camera off
    /// (`MonitorModel.setAsleep`), and the session is then thrown away as too short. The
    /// routine timer does the same for a Mac under a mask (`RoutineSessionController`).
    private func stayAwake(_ reason: String) {
        guard awake == nil else { return }
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: reason)
    }

    private func letSleep() {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func runSession() async {
        let pace = parts.pace
        let writer: SessionWriter
        do {
            try PrivateFolder.create(at: parts.sessionsRoot)
            writer = try SessionWriter(root: parts.sessionsRoot, session: SessionScript.sessionName(at: Date()), condition: "")
        } catch {
            facts.problem = "The recording could not be saved: \(error.localizedDescription)"
            return
        }
        let number = facts.sessions.count
        facts.sessionOpen = 0
        facts.sessionClosed = 0
        facts.problem = nil
        facts.sessionNote = nil
        facts.phaseIndex = 0
        facts.phaseState = .listening
        if pace.spoken { await speaker.say("Starting. Follow my voice, and blink whenever you need to.") }

        facts.lostPoses = []
        for (index, phase) in SessionScript.phases.enumerated() {
            // A POSE THAT LOST THE FACE IS ASKED FOR AGAIN, ONCE. Chin down, head turned,
            // leaned back: the poses themselves are what hides a face from the camera, and
            // the person has their eyes closed. Before this, nothing was said until the
            // whole session was refused two minutes later.
            for attempt in 0..<2 {
                if Task.isCancelled { break }
                facts.phaseIndex = index
                facts.phaseState = .listening
                parts.painted?.follow(.hold(phase, session: number))
                if attempt > 0, pace.spoken { await speaker.say(SessionCheck.faceLostWords) }
                if attempt == 0, pace.spoken, let words = SessionScript.progressWords(before: index) { await speaker.say(words) }
                if pace.spoken { await speaker.say(phase.instruction) }
                if Task.isCancelled { break }

                facts.phaseState = .settling
                // A steady change of brightness ends here, a second before pictures are
                // taken again: the screen lights the face, and the camera needs a moment.
                if facts.glow != 0, reduceMotion() { facts.glow = 0 }
                await pause(pace.settleSeconds)
                if Task.isCancelled { break }

                facts.phaseState = .recording
                let before = facts.sessionOpen + facts.sessionClosed
                withAnimation(.linear(duration: pace.recordSeconds)) { facts.recordProgress = 1 }
                pipeline.setRecording(SessionPipeline.Recording(writer: writer, phaseIndex: index, phase: phase))
                await pause(pace.recordSeconds)
                pipeline.setRecording(nil)
                facts.recordProgress = 0
                if pace.spoken { NSSound(named: "Tink")?.play() }   // audible with eyes closed: "this pose is done"
                if !Task.isCancelled { show(PoseSignal.atEnd(of: phase.label, pace: pace, reduceMotion: reduceMotion())) }

                if Task.isCancelled { break }
                if SessionCheck.poseIsWhole(pictures: facts.sessionOpen + facts.sessionClosed - before, pace: pace) { break }
                if attempt == 1 { facts.lostPoses.append(phase) }
            }
        }

        pipeline.setRecording(nil)
        parts.painted?.follow(.look)
        let stopped = Task.isCancelled
        facts.phaseState = .idle
        facts.recordProgress = 0
        if stopped { facts.glow = 0 }
        if !stopped && pace.spoken { await speaker.say("Finished. You can open your eyes.") }
        // A steady brightening after a last closed-eye pose lasts as long as those words.
        // (A pulse ends by itself.)
        if reduceMotion(), facts.glow != 0 { facts.glow = 0 }
        await pause(0.1)                         // the last frames' counts are on their way
        sessionEnded(folder: writer.folder, stopped: stopped)
    }

    /// A session is over: keep it if it is whole, say why not otherwise.
    func sessionEnded(folder: URL, stopped: Bool) {
        let pictures = facts.sessionOpen + facts.sessionClosed
        let share = SessionCheck.share(pictures: pictures, pace: parts.pace)
        // Stopped late, a recording that passes its check is kept: a stray click at pose 15
        // of 16 threw two minutes away (audit of 22 November 2026, item 2.1).
        if share < SessionCheck.smallestShare {
            // A developer's folder is not ours to empty: there, the session goes to the Trash.
            try? SessionStore.discard(folder, toTrash: !parts.ownSessions)
            let fate = parts.ownSessions ? "It was not kept." : "It was moved to the Trash."
            let lost = facts.lostPoses.map(\.poseName).joined(separator: "; ")
            facts.sessionNote = stopped
                ? "Stopped. A recording is only used when it is complete. \(fate)"
                : "The camera lost your face for about \(100 - Int(share * 100))% of that recording"
                    + (lost.isEmpty ? ". " : ", most of all during: \(lost). ")
                    + "\(fate) Record it again: in those poses, move your head a little less."
        }
        rescan()
    }

    // MARK: - Training

    /// "Train my model": leaves the camera and starts a training.
    func train() {
        guard !facts.sessionRunning, !facts.sessions.isEmpty else { return }
        enter(.train)
        startTraining()
    }

    func retryTraining() {
        startTraining()
    }

    private func startTraining() {
        job?.cancel()
        facts.training = .waiting
        lastTrainingWord = Date()
        facts.trainingSilent = false
        // The camera's own timer is off during a training: this one asks once a second,
        // and ends with the training.
        trainingWatch?.cancel()
        trainingWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.checkTraining() else { return }
            }
        }
        facts.alteredSamples = []
        prepareSamples()
        do {
            try parts.store.prepareStaging()
        } catch {
            trainerSaid(.failed("The model's folder could not be prepared: \(error.localizedDescription)"))
            return
        }
        let job = TrainingJob(way: parts.trainingWay, sessions: parts.sessionsRoot, staging: parts.store.staging,
                              passes: parts.passes) { [weak self] in self?.trainerSaid($0) }
        self.job = job
        job.start()
    }

    /// What the trainer says, as it says it.
    func trainerSaid(_ progress: TrainingProgress) {
        guard facts.step == .train else { return }
        lastTrainingWord = Date()
        facts.trainingSilent = false
        switch progress {
        case .reading(let done, let total):
            facts.training = .reading(done: done, total: total)
        case .learning(let pass, let of, _, let seconds):
            // The time left is measured, not guessed: the passes made so far say how long
            // one takes on THIS Mac. The first includes warming up, so it is not trusted alone.
            let left = pass >= 2 ? seconds / Double(pass) * Double(of - pass) : nil
            facts.training = .learning(pass: pass, of: of, secondsLeft: left)
            showSamples(pass: pass)
        case .checking:
            facts.training = .checking
        case .failed(let reason):
            failedTrainings += 1
            job = nil
            parts.store.discardStaging()
            facts.training = .failed(reason: reason, attempts: failedTrainings)
            Log.app.error("Training failed: \(reason, privacy: .public)")
        case .finished:
            job = nil
            do {
                // Only now does the new model take the place of the old one.
                try parts.store.installStaged()
                failedTrainings = 0
                rescan()
                facts.training = .done
            } catch {
                failedTrainings += 1
                facts.training = .failed(reason: "The trained model could not be put in place: \(error)", attempts: failedTrainings)
            }
        }
    }

    /// Picks a few pictures to show while training: as many open as closed.
    private func prepareSamples() {
        let entries = TrainingSet.list(root: parts.sessionsRoot)
        let open = entries.filter { !$0.closed }, closed = entries.filter(\.closed)
        var chosen: [TrainingSet.Entry] = []
        for group in [open, closed] where !group.isEmpty {
            for index in 0..<3 { chosen.append(group[(index * 2 + 1) * group.count / 6]) }
        }
        sampleSources = chosen.compactMap { TrainingSet.gray(contentsOf: $0.file) }
        showSamples(pass: 0)
    }

    /// The same pictures, altered the way this pass alters them.
    private func showSamples(pass: Int) {
        var altered = [Float](repeating: 0, count: EyeNetwork.pixels)
        facts.alteredSamples = sampleSources.enumerated().compactMap { index, source in
            guard pass > 0 else { return TrainingSet.image(fromGray: source) }
            var random = SeededRandom(seed: UInt64(pass * 100 + index))
            PictureAlteration.apply(source, into: &altered, random: &random)
            return TrainingSet.image(fromGray: altered)
        }
    }

    // MARK: - The test

    /// "Test it", after a training.
    func beginProof() {
        guard facts.info != nil else { return }
        enter(.proof)
    }

    var canStartTest: Bool { facts.step == .proof && facts.camera == .on && facts.faceFound && facts.proof != .running }

    /// Ten ticks; a blink at each.
    func startTest() {
        guard canStartTest else { return }
        facts.proofTest = ProofTest()
        facts.proof = .running
        stayAwake("The test at the end of the setup")
        testTask = Task {
            defer { letSleep() }
            await pause(ProofTest.secondsBeforeFirstTick)     // "Get ready"
            for _ in 0..<ProofTest.ticks {
                if Task.isCancelled { return }
                (tickSound?.copy() as? NSSound)?.play()
                pipeline.markTick()
                parts.painted?.follow(.blink)
                await pause(ProofTest.secondsBetweenTicks)
            }
            await pause(0.3)                     // the last blink may still be closing
            if !Task.isCancelled { testEnded() }
        }
    }

    /// The test is over: its result is written next to the model it tested.
    func testEnded(now: Date = Date()) {
        let result = facts.proofTest.result
        facts.proof = .finished(result)
        facts.failedTests = result.passed ? 0 : facts.failedTests + 1
        try? parts.store.setProof(ModelInfo.Proof(found: result.found, of: result.of, extra: result.extra, on: now,
                                                  accepted: result.passed))
        rescan()
    }

    /// "Test again".
    func testAgain() {
        testTask?.cancel()
        facts.proof = .ready
        facts.proofTest = ProofTest()
    }

    /// "Record one more session", after a test that failed: back to the camera, then
    /// train again on everything.
    func recordOneMore() {
        testTask?.cancel()
        facts.targetSessions = facts.sessions.count + 1
        facts.sessionNote = nil
        facts.failedTests = 0
        enter(.record)
    }

    /// "Use it anyway": your call. The result stays written as it was.
    func useAnyway() {
        if var tested = facts.info?.proof {
            tested.accepted = true
            try? parts.store.setProof(tested)
        }
        finish()
    }

    /// "Go back to the model I had": the one before the last training.
    func goBackToPrevious() {
        try? parts.store.restorePrevious()
        finish()
    }

    // MARK: - By itself

    /// Goes through the whole setup with nobody at the keyboard: each button is pressed
    /// as soon as it can be. Only on painted eyes (`--play-setup`, in the demo): it is how
    /// the window, the helper process and everything between them are exercised without a
    /// click, and its steps are written to the log.
    func play() async {
        guard parts.painted != nil else { return }
        func wait(for what: String, _ done: @escaping () -> Bool) async -> Bool {
            for _ in 0..<1200 where !done() { await pause(0.1) }
            if !done() { Log.app.error("Setup by itself: gave up waiting for \(what, privacy: .public)") }
            return done()
        }
        if facts.step == .welcome { begin() }
        guard await wait(for: "a face", { self.canLeaveCameraCheck }) else { return }
        cameraLooksRight()
        while !enoughSessions {
            guard await wait(for: "a face before a session", { self.canStartSession }) else { return }
            startSession()
            guard await wait(for: "the end of the session", { !self.facts.sessionRunning }) else { return }
            Log.app.notice("Setup by itself: \(self.facts.sessions.count, privacy: .public) sessions, \(self.facts.sessionOpen + self.facts.sessionClosed, privacy: .public) pictures in the last")
            if facts.sessionNote != nil { return }
        }
        train()
        guard await wait(for: "the training", { self.facts.training == .done || self.failedTrainings > 0 }) else { return }
        guard facts.training == .done, let trained = facts.info else {
            Log.app.error("Setup by itself: the training failed")
            return
        }
        Log.app.notice("Setup by itself: trained on \(trained.pictures, privacy: .public) pictures in \(trained.seconds, privacy: .public) s, \(trained.rightOnOwnPictures, privacy: .public) of its own right")
        beginProof()
        guard await wait(for: "a face before the test", { self.canStartTest }) else { return }
        startTest()
        guard await wait(for: "the end of the test", { if case .finished = self.facts.proof { return true } else { return false } }) else { return }
        if case .finished(let result) = facts.proof {
            Log.app.notice("Setup by itself: \(result.found, privacy: .public) of \(result.of, privacy: .public) blinks counted, \(result.extra, privacy: .public) more")
        }
        finish()
    }

    /// Setup is over: from the next frame on, the app counts with the model.
    func finish() {
        testTask?.cancel()
        rescan()
        guard facts.info?.isAccepted ?? false else { return }
        enter(.done)
        Task {
            // The model first, the camera second: it then never goes off in between.
            await monitor.modelChanged()
            monitor.leaveSetup()
        }
    }
}
