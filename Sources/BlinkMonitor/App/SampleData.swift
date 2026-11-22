import AppKit
import BlinkCore

/// A made-up but plausible week of use: the same at every run, never written to the user's
/// own files. The screenshots are drawn from it, and the demo starts from it.
@MainActor
enum SampleData {

    /// The situations the screenshots show.
    enum Scene {
        /// After a week of use, at a healthy rate, with a reference measured.
        case watching
        /// The last hours were a stretch of deep concentration: the rate is under the
        /// limit, and under a reference measured in better weeks.
        case low
        /// Paused for a while.
        case paused
        /// The first afternoon: no reference yet, and the look-away nudges switched on.
        case learning
        /// In the middle of a blink break, `count` blinks in.
        case blinkBreak(count: Int)
        /// A minute after the very first launch: nothing recorded yet.
        case firstMinute
        /// The camera has stopped sending pictures (the lid is closed).
        case noPicture
        /// The demo: `watching`, on made-up eyes.
        case demo
        /// A new Mac: no model of your eyes yet, the setup window closed.
        case needsSetup
        /// The setup window is recording a session.
        case settingUp
    }

    /// A history file of its own, emptied at each start: made-up minutes must never
    /// reach the user's real history.
    static func scratchHistory() -> HistoryStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-sample-history.csv")
        try? FileManager.default.removeItem(at: file)
        return HistoryStore(file: file)
    }

    /// The demo as it starts: a week of made-up history, a reference, and made-up eyes in
    /// place of the camera (`MonitorModel(demo:)`).
    static func demoModel(now: Date = Date()) -> MonitorModel {
        let minutes = self.minutes(now: now, low: false)
        let preferences = Preferences.temporary()
        preferences.reference = Reference(rate: Baseline.medianRate(of: minutes) ?? 13,
                                          measuredOn: now.addingTimeInterval(-17 * 86_400), minutes: 214)
        return MonitorModel(preferences: preferences,
                            history: HistoryController(store: scratchHistory(), minutes: minutes), demo: true)
    }

    /// The app in one of those situations.
    static func model(now: Date, scene: Scene) -> MonitorModel {
        var isLow = false
        if case .low = scene { isLow = true }

        var live = LiveState()
        live.faceFound = true
        live.eyeRects = [CGRect(x: 760, y: 430, width: 130, height: 130), CGRect(x: 1030, y: 425, width: 130, height: 130)]
        live.probability = 0.02
        live.eyeAnswers = [.imageLeft: 0.03, .imageRight: 0.01]
        live.counters.ratePerMinute = isLow ? 6 : 13
        live.counters.blinksLastMinute = isLow ? 6 : 13
        live.counters.totalBlinks = 148
        live.counters.longClosures = 3
        live.counters.observedSeconds = 11 * 60 + 42
        live.counters.lastBlinkSeconds = 0.167

        var timings = StageTimings.Summary()
        timings.findEyes = 8.9
        timings.crop = 1.3
        timings.model = 0.7
        timings.total = 11.6
        timings.worstTotal = 24.5
        timings.framesPerSecond = 30
        timings.analysedShare = 1

        var initial = MonitorModel.InitialState(live: live, curve: curve(), timings: timings,
                                                cameraNote: "The camera picture is left out of screenshots.",
                                                modelSource: .trainedHere(modelInfo(now: now)))
        var minutes = self.minutes(now: now, low: isLow)
        // A store of their own: the screenshots must not depend on the user's settings.
        let preferences = Preferences.temporary()
        let usual = Baseline.medianRate(of: minutes) ?? 13
        let aWhileAgo = now.addingTimeInterval(-17 * 86_400)

        var isDemo = false
        switch scene {
        case .watching:
            preferences.reference = Reference(rate: usual, measuredOn: aWhileAgo, minutes: 214)
        case .demo:
            preferences.reference = Reference(rate: usual, measuredOn: aWhileAgo, minutes: 214)
            initial.cameraNote = nil
            initial.modelSource = .none
            isDemo = true
        case .needsSetup, .settingUp:
            minutes = []
            initial.lifecycle = .needsSetup
            initial.live = LiveState()
            initial.modelSource = .none
            if case .settingUp = scene {
                initial.setupStage = .recording
                preferences.welcomed = true
            }
        case .noPicture:
            preferences.reference = Reference(rate: usual, measuredOn: aWhileAgo, minutes: 214)
            initial.cameraSilent = true
            initial.live = live.withCameraOff
        case .firstMinute:
            minutes = []
            initial.live.counters = BlinkStats.Snapshot()
            initial.live.counters.observedSeconds = 12
        case .low:
            preferences.reference = Reference(rate: (usual * 1.3 * 10).rounded() / 10, measuredOn: aWhileAgo, minutes: 214)
            preferences.floor = 8
        case .paused:
            preferences.reference = Reference(rate: usual, measuredOn: aWhileAgo, minutes: 214)
            initial.pause = .paused(until: now.addingTimeInterval(33 * 60))
            initial.live = live.withCameraOff
        case .learning:
            minutes.removeAll { $0.start < now.addingTimeInterval(-100 * 60) }      // installed this afternoon
            preferences.breakNudgesOn = true
            initial.screenMinutes = 34
        case .blinkBreak(let count):
            preferences.reference = Reference(rate: usual, measuredOn: aWhileAgo, minutes: 214)
            var exercise = BlinkBreak()
            for _ in 0..<count { exercise.record(.blink(Blink(start: 0, end: 0.3))) }
            initial.blinkBreak = exercise
        }
        // The minute in progress: 38 seconds in.
        var current: MinuteRecord? = MinuteRecord(start: MinuteRecord.minuteStart(of: now), observedSeconds: 36,
                                                  blinks: isLow ? 4 : 8)
        if case .firstMinute = scene { current = nil }
        if initial.lifecycle == .needsSetup { current = nil }
        return MonitorModel(preferences: preferences,
                            history: HistoryController(store: scratchHistory(), minutes: minutes, current: current),
                            initial: initial, demo: isDemo)
    }

    // MARK: - The setup

    /// A model as setup leaves it: two sessions, trained in eleven seconds, tested.
    static func modelInfo(now: Date, found: Int? = 10) -> ModelInfo {
        ModelInfo(trainedOn: now.addingTimeInterval(-3 * 86_400), sessions: ["20261117-093012", "20261117-093655"],
                  openPictures: 962, closedPictures: 950, passes: TrainingRun.passes, seconds: 10.6, lastLoss: 0.004,
                  rightOnOwnPictures: 1910, largestDifference: 0.000001,
                  proof: found.map { ModelInfo.Proof(found: $0, of: ProofTest.ticks, extra: 0, on: now.addingTimeInterval(-3 * 86_400),
                                                     accepted: $0 >= ProofTest.passMark) })
    }

    /// Where the demo's setup writes: a folder of its own, emptied at each start. Painted
    /// sessions and the model trained on them must never reach the user's own files.
    static func demoSetupParts(monitor: MonitorModel) -> SetupModel.Parts {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-demo-setup", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        return SetupModel.Parts(monitor: monitor, store: ModelStore(base: folder),
                                sessionsRoot: folder.appendingPathComponent("sessions", isDirectory: true),
                                pace: .painted, painted: PaintedCamera())
    }

    /// The moments of the setup that the screenshots show.
    enum SetupScene {
        case welcome, demoWelcome
        case camera, cameraNoFace, cameraDark, cameraRefused
        case recordFirst, recording, recordShort, recordNext, recordEnough
        case training, trainingFailed, trainingFailedAgain, trained
        case testReady, testRunning, testPassed, testFailed
        case done
    }

    /// The setup window at one of those moments: stated, with no camera and no disk.
    static func setup(_ scene: SetupScene, now: Date) -> SetupModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-sample-setup", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        var monitorScene = Scene.needsSetup
        if case .demoWelcome = scene { monitorScene = .demo }
        let parts = SetupModel.Parts(monitor: model(now: now, scene: monitorScene), store: ModelStore(base: folder),
                                     sessionsRoot: folder.appendingPathComponent("sessions", isDirectory: true))

        func session(_ name: String, _ open: Int, _ closed: Int) -> SessionSummary {
            SessionSummary(name: name, folder: parts.sessionsRoot.appendingPathComponent(name), open: open, closed: closed)
        }
        let first = session("20261120-093012", 478, 470), second = session("20261120-093655", 484, 480)
        let openEyes = [PaintedEye(openness: 0.9, light: 0.72).image(), PaintedEye(openness: 0.9, light: 0.66, noseOnRight: false).image()]
        let closedEyes = [PaintedEye(openness: 0, light: 0.72).image(), PaintedEye(openness: 0, light: 0.66, noseOnRight: false).image()]

        var state = SetupModel.InitialState()
        state.crops = openEyes
        switch scene {
        case .welcome, .demoWelcome:
            state.step = .welcome
        case .camera:
            state.step = .camera
        case .cameraNoFace:
            state.step = .camera
            (state.faceFound, state.faceMissing, state.crops) = (false, true, [nil, nil])
        case .cameraDark:
            state.step = .camera
            state.brightness = 41
            state.crops = [PaintedEye(openness: 0.9, light: 0.22).image(), PaintedEye(openness: 0.9, light: 0.18, noseOnRight: false).image()]
        case .cameraRefused:
            state.step = .camera
            (state.camera, state.faceFound, state.crops) = (.refused, false, [nil, nil])
        case .recordFirst:
            state.step = .record
        case .recording:
            state.step = .record
            state.sessions = [first]
            (state.sessionRunning, state.phaseIndex, state.phaseState, state.recordProgress) = (true, 5, .recording, 0.6)
            (state.sessionOpen, state.sessionClosed, state.crops) = (178, 148, closedEyes)
        case .recordShort:
            state.step = .record
            state.sessions = [first]
            state.sessionNote = "That session holds 58% of what it should: your face was out of view during some poses. "
                + "It was not kept. Record it again, staying in front of the camera."
            (state.sessionOpen, state.sessionClosed) = (301, 256)
        case .recordNext:
            state.step = .record
            state.sessions = [first]
            (state.sessionOpen, state.sessionClosed) = (first.open, first.closed)
        case .recordEnough:
            state.step = .record
            state.sessions = [first, second]
            (state.sessionOpen, state.sessionClosed) = (second.open, second.closed)
        case .training:
            state.step = .train
            state.sessions = [first, second]
            state.training = .learning(pass: 12, of: TrainingRun.passes, secondsLeft: 6.4)
            state.alteredSamples = alteredSamples(pass: 12)
        case .trainingFailed, .trainingFailedAgain:
            state.step = .train
            state.sessions = [first, second]
            var attempts = 1
            if case .trainingFailedAgain = scene { attempts = 2 }
            state.training = .failed(reason: "The trainer stopped before the end (signal 6).\n"
                + "MPSGraphVariable.mm:69: failed assertion `multi-device variable handling not correcly implemented'", attempts: attempts)
        case .trained:
            state.step = .train
            state.sessions = [first, second]
            state.info = modelInfo(now: now, found: nil)
            state.training = .done
            state.alteredSamples = alteredSamples(pass: 0)
        case .testReady:
            state.step = .proof
            state.info = modelInfo(now: now, found: nil)
        case .testRunning:
            state.step = .proof
            state.info = modelInfo(now: now, found: nil)
            state.proof = .running
            state.proofTest = proofTest(ticks: 6, missed: [2])
        case .testPassed:
            state.step = .proof
            state.info = modelInfo(now: now, found: 10)
            state.proofTest = proofTest(ticks: 10, missed: [])
            state.proof = .finished(state.proofTest.result)
        case .testFailed:
            state.step = .proof
            state.info = modelInfo(now: now, found: 6)
            state.proofTest = proofTest(ticks: 10, missed: [1, 4, 5, 8])
            state.proof = .finished(state.proofTest.result)
            state.hasPrevious = true
        case .done:
            state.step = .done
            state.sessions = [first, second]
            state.info = modelInfo(now: now, found: 10)
            (state.megabytes, state.place) = (19, "~/Library/Application Support/BlinkMonitor")
        }
        return SetupModel(parts: parts, initial: state)
    }

    /// A test in progress: `ticks` played, each answered by a blink except the `missed`
    /// ones (and the last one, which is still being answered).
    static func proofTest(ticks: Int, missed: Set<Int>) -> ProofTest {
        var test = ProofTest()
        for tick in 0..<ticks {
            let time = 100 + Double(tick) * ProofTest.secondsBetweenTicks
            test.tick(at: time)
            let pending = ticks < ProofTest.ticks && tick == ticks - 1
            if !missed.contains(tick) && !pending { test.blink(Blink(start: time + 0.3, end: time + 0.45)) }
        }
        return test
    }

    /// Six painted eyes, altered the way a training pass alters real ones.
    static func alteredSamples(pass: Int) -> [CGImage] {
        let eyes = [PaintedEye(openness: 0.9), PaintedEye(openness: 0.55, gaze: CGPoint(x: 0.6, y: 0.2), noseOnRight: false),
                    PaintedEye(openness: 1, scale: 1.15, light: 0.55), PaintedEye(openness: 0),
                    PaintedEye(openness: 0, scale: 0.85, light: 0.6, noseOnRight: false), PaintedEye(openness: 0, tilt: 0.25)]
        var altered = [Float](repeating: 0, count: EyeNetwork.pixels)
        return eyes.enumerated().compactMap { index, eye in
            guard let gray = eye.buffer().flatMap(TrainingSet.gray(of:)) else { return nil }
            guard pass > 0 else { return TrainingSet.image(fromGray: gray) }
            var random = SeededRandom(seed: UInt64(pass * 100 + index))
            PictureAlteration.apply(gray, into: &altered, random: &random)
            return TrainingSet.image(fromGray: altered)
        }
    }

    /// Ten seconds of the model's answers, with three blinks in them.
    static func curve() -> Curve {
        let blinkStarts = [91.4, 94.9, 98.1]
        var curve = Curve()
        curve.now = 100
        curve.samples = (0..<300).map { frame in
            let time = 90 + Double(frame) / 30
            let inBlink = blinkStarts.contains { time >= $0 && time < $0 + 0.13 }
            let edge = blinkStarts.contains { (time >= $0 - 0.034 && time < $0) || (time >= $0 + 0.13 && time < $0 + 0.165) }
            return TraceSample(time: time, probability: inBlink ? 0.98 : (edge ? 0.45 : 0.02))
        }
        curve.blinks = blinkStarts.map { Blink(start: $0, end: $0 + 0.16) }
        return curve
    }

    /// One working week of minutes: mornings at a healthy rate, fewer blinks after lunch.
    static func minutes(now: Date, low: Bool, calendar: Calendar = .current) -> [MinuteRecord] {
        var seed: UInt64 = 20_261_120
        func random() -> Double {                 // a small fixed generator: same data every time
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var sample: [MinuteRecord] = []
        let today = calendar.startOfDay(for: now)
        for back in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  !calendar.isDateInWeekend(day) else { continue }
            let dayLevel = [15.5, 13.0, 14.5, 11.5, 14.0, 16.0, 13.5][back % 7]
            for hour in [9, 10, 11, 13, 14, 15, 16, 17] {
                for minute in 0..<60 {
                    guard let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                          start < now, random() > 0.12 else { continue }      // away now and then
                    // Deep concentration after lunch: fewer blinks. (`low`: it lasts until now.)
                    let deep = hour == 14 || hour == 15 || (low && hour >= 16)
                    let focus = deep ? 0.58 : (hour == 10 ? 0.85 : 1.0)
                    let rate = max(2, dayLevel * focus + (random() - 0.5) * 9)
                    let watched = 48 + random() * 12
                    sample.append(MinuteRecord(start: start, observedSeconds: watched,
                                               blinks: Int((rate * watched / 60).rounded())))
                }
            }
        }
        // The last three minutes decide "low or not": state them, do not leave them to chance.
        let minuteNow = MinuteRecord.minuteStart(of: now)
        sample.removeAll { $0.start >= minuteNow.addingTimeInterval(-180) }
        for back in [3, 2, 1] {
            sample.append(MinuteRecord(start: minuteNow.addingTimeInterval(-Double(back) * 60),
                                       observedSeconds: 58, blinks: low ? 6 : 13))
        }
        return sample
    }
}
