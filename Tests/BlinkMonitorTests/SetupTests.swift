import CoreGraphics
import Foundation
import Testing
import BlinkCore
@testable import BlinkMonitor

/// The setup, without a camera: its states driven by hand, then the whole of it on
/// painted eyes.
@MainActor
@Suite("The setup", .serialized)
struct SetupTests {

    /// A setup over a folder of its own, with painted eyes ready and the trainer run in
    /// this process. The app's model is a demo one: it never touches the camera.
    @MainActor
    private final class Bench {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("blink-setup-tests-\(UUID().uuidString)", isDirectory: true)
        let monitor = SampleData.demoModel()
        let painted = PaintedCamera()
        lazy var parts = SetupModel.Parts(monitor: monitor, store: ModelStore(base: base),
                                          sessionsRoot: base.appendingPathComponent("sessions", isDirectory: true),
                                          pace: SessionPace(settleSeconds: 0.05, recordSeconds: 0.3, saveEveryNthFrame: 1, spoken: false),
                                          painted: painted, trainingWay: .inProcess, passes: 8)
        lazy var setup = SetupModel(parts: parts)

        deinit { try? FileManager.default.removeItem(at: base) }

        /// A session on disk, as a finished recording leaves it.
        func record(_ name: String, pictures: Int) throws {
            let writer = try SessionWriter(root: parts.sessionsRoot, session: name, condition: "")
            var random = SeededRandom(seed: UInt64(pictures))
            let square = CGRect(x: 800, y: 400, width: 128, height: 128)
            let eye = EyeRegion(side: .imageLeft, cropRect: square, center: CGPoint(x: square.midX, y: square.midY))
            let located = LocatedEyes(faceRect: .zero, left: eye, right: eye, interocularDistance: 260, roll: 0, yaw: nil)
            for index in 0..<pictures {
                let open = index % 2 == 0
                guard let image = PaintedEye.random(open: open, using: &random).image() else { continue }
                writer.save(EyeSample(image: image, label: open ? .open : .closed, variant: "painted", phaseIndex: 0, frameIndex: index,
                                      time: 0, eye: eye, located: located, frameSize: CGSize(width: 1920, height: 1080)))
            }
        }

        /// A model in `model.new`, as a finished training leaves it.
        func stageModel() throws {
            try parts.store.prepareStaging()
            let flat = [Float](repeating: 0, count: 60_289)
            try EyeNetWeights(flat: flat).write(to: parts.store.staging.appendingPathComponent(ModelStore.weightsName))
            try info().write(to: parts.store.staging.appendingPathComponent(ModelStore.infoName))
        }

        func info() -> ModelInfo {
            ModelInfo(trainedOn: Date(timeIntervalSince1970: 1_800_000_000), sessions: ["a", "b"], openPictures: 200, closedPictures: 200,
                      passes: 8, seconds: 3, lastLoss: 0.01, rightOnOwnPictures: 400, largestDifference: 0)
        }
    }

    private func frame(face: Bool = true, time: Double, side: Int = 120, brightness: Double = 130) -> SessionFrame {
        var frame = SessionFrame()
        frame.time = time
        frame.faceFound = face
        frame.cropSide = face ? side : 0
        frame.brightness = face ? brightness : nil
        return frame
    }

    /// Waits for something that another thread brings about. Fails the test after `seconds`.
    private func wait(_ seconds: Double, for what: String, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < end else {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: Where it opens

    @Test("The step to open on is read from what is on disk")
    func resumeStep() {
        let untested = Bench().info()
        var accepted = untested, refused = untested
        accepted.proof = ModelInfo.Proof(found: 10, of: 10, extra: 0, on: Date(), accepted: true)
        refused.proof = ModelInfo.Proof(found: 5, of: 10, extra: 0, on: Date(), accepted: false)

        #expect(SetupModel.resumeStep(completeSessions: 0, info: nil, welcomed: false) == .welcome)
        #expect(SetupModel.resumeStep(completeSessions: 0, info: nil, welcomed: true) == .camera)
        #expect(SetupModel.resumeStep(completeSessions: 1, info: nil, welcomed: false) == .camera)
        #expect(SetupModel.resumeStep(completeSessions: 2, info: untested, welcomed: true) == .proof)
        #expect(SetupModel.resumeStep(completeSessions: 2, info: refused, welcomed: true) == .proof)
        #expect(SetupModel.resumeStep(completeSessions: 2, info: accepted, welcomed: true) == .done)
    }

    @Test("Opening counts the whole sessions on disk and ignores a partial one; the app says setup is at work")
    func opening() throws {
        let bench = Bench()
        let full = bench.parts.pace.fullSessionPictures
        try bench.record("20270101-090000", pictures: full)
        try bench.record("20270101-100000", pictures: full / 2)          // the window was closed in the middle

        bench.setup.open()
        #expect(bench.setup.sessions.map(\.name) == ["20270101-090000"])
        #expect(bench.setup.step == .camera && bench.setup.camera == .on)
        #expect(bench.setup.nextSession == 2 && !bench.setup.enoughSessions)
        #expect(bench.monitor.setupStage == .checkingCamera)

        bench.setup.close()
        #expect(bench.monitor.setupStage == nil)
        #expect(bench.setup.camera == .off)
    }

    // MARK: The camera check

    @Test("The camera check waits for a steady face, and says so when there is none, when it is far or when it is dark")
    func cameraCheck() {
        let bench = Bench()
        bench.monitor.preferences.welcomed = true
        bench.setup.open()
        bench.painted.stop()                                             // frames by hand from here on

        // Nobody: after three seconds it is said, and the way on stays shut.
        for index in 0..<120 { bench.setup.apply(frame(face: false, time: 10 + Double(index) / 30)) }
        #expect(bench.setup.faceMissing && !bench.setup.canLeaveCameraCheck)
        bench.setup.cameraLooksRight()
        #expect(bench.setup.step == .camera)

        // Someone sits down: a second of frames is enough.
        for index in 0..<30 { bench.setup.apply(frame(time: 14 + Double(index) / 30)) }
        #expect(!bench.setup.faceMissing && bench.setup.faceInView && bench.setup.canLeaveCameraCheck)
        #expect(bench.setup.eyesLargeEnough && bench.setup.lightEnough && bench.setup.brightness == 130)

        // Far away, in the dark: warnings, not a wall.
        for index in 0..<30 { bench.setup.apply(frame(time: 15 + Double(index) / 30, side: 48, brightness: 35)) }
        #expect(!bench.setup.eyesLargeEnough && !bench.setup.lightEnough && bench.setup.canLeaveCameraCheck)

        // The camera stops sending pictures (the lid is closed).
        let last = Date()
        bench.setup.apply(frame(time: 16), now: last)
        bench.setup.checkForSilence(now: last.addingTimeInterval(3))
        #expect(!bench.setup.cameraSilent)
        bench.setup.checkForSilence(now: last.addingTimeInterval(6))
        #expect(bench.setup.cameraSilent)

        bench.setup.cameraLooksRight()
        #expect(bench.setup.step == .record)
        #expect(bench.monitor.setupStage == .recording)
        bench.setup.close()
    }

    // MARK: Recording

    @Test("A session that holds too little is not kept, and the window says why")
    func shortSession() throws {
        let bench = Bench()
        let full = bench.parts.pace.fullSessionPictures
        try bench.record("20270101-090000", pictures: full)
        try bench.record("20270101-100000", pictures: full / 2)
        bench.monitor.preferences.welcomed = true
        bench.setup.open()
        bench.painted.stop()
        var saved = frame(time: 1)
        saved.savedOpen = full / 4
        saved.savedClosed = full / 4
        bench.setup.apply(saved)

        let folder = bench.parts.sessionsRoot.appendingPathComponent("20270101-100000")
        bench.setup.sessionEnded(folder: folder, stopped: false)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(bench.setup.sessionNote?.contains("about 50%") == true)
        #expect(bench.setup.sessions.count == 1 && !bench.setup.enoughSessions)

        // A whole one counts, and two are enough to train.
        try bench.record("20270101-110000", pictures: full)
        saved.savedOpen = full / 2
        saved.savedClosed = full / 2
        bench.setup.apply(saved)
        bench.setup.sessionEnded(folder: bench.parts.sessionsRoot.appendingPathComponent("20270101-110000"), stopped: false)
        #expect(bench.setup.sessions.count == 2 && bench.setup.enoughSessions)

        // Stopped late, a recording that passes its check is kept.
        try bench.record("20270101-120000", pictures: full)
        bench.setup.sessionEnded(folder: bench.parts.sessionsRoot.appendingPathComponent("20270101-120000"), stopped: true)
        #expect(bench.setup.sessions.count == 3, "\(bench.setup.sessions.map(\.name)) \(bench.setup.sessionNote ?? "-")")
        bench.setup.close()
    }

    // MARK: Training

    @Test("A failed training is said in a sentence for a person, never as the trainer's own words")
    func trainingFailureWords() {
        let crash = "The training program stopped before the end (signal 6).\nMPSGraphVariable.mm:69: failed assertion"
        #expect(TrainingFailureWords.plain(crash) == "The training program stopped unexpectedly.")
        #expect(!TrainingFailureWords.plain(crash).contains("signal"))
        #expect(TrainingFailureWords.plain("The training program stopped answering, and was ended.").contains("was ended"))
        // What the training said itself is a sentence already: its first line is kept.
        #expect(TrainingFailureWords.plain("Too few pictures to learn from.\nmore") == "Too few pictures to learn from.")
        #expect(TrainingFailureWords.plain("") == "The training stopped.")
    }

    @Test("A pose that kept under half its pictures lost the face; the test waits two seconds before its first tick")
    func poseAndLeadIn() {
        let full = SessionPace.usual.fullSessionPictures / SessionScript.phases.count
        #expect(full == 60)
        #expect(SessionCheck.poseIsWhole(pictures: 60))
        #expect(SessionCheck.poseIsWhole(pictures: 30))
        #expect(!SessionCheck.poseIsWhole(pictures: 29))
        #expect(!SessionCheck.poseIsWhole(pictures: 0))
        #expect(SessionScript.phases[5].poseName == "eyes closed, chin down")
        #expect(ProofTest.secondsBeforeFirstTick >= 2)
    }

    @Test("A training that fails can be tried again; the second failure shows its reason; a finished one is installed")
    func trainingWords() throws {
        let bench = Bench()
        try bench.record("20270101-090000", pictures: bench.parts.pace.fullSessionPictures)
        bench.monitor.preferences.welcomed = true
        bench.setup.open()
        bench.setup.cameraLooksRight()
        bench.setup.train()
        #expect(bench.setup.step == .train && bench.setup.camera == .off)
        #expect(bench.monitor.setupStage == .training)
        bench.setup.close()                                              // ends the real training: the words come by hand
        bench.setup.open(.addSession)
        bench.setup.cameraLooksRight()
        #expect(bench.setup.step == .camera)                             // no steady face yet
        for index in 0..<30 { bench.setup.apply(frame(time: Double(index) / 30)) }
        bench.setup.cameraLooksRight()
        bench.setup.train()

        bench.setup.training(.reading(done: 10, total: 400))
        #expect(bench.setup.training == .reading(done: 10, total: 400))
        bench.setup.training(.learning(pass: 1, of: 8, loss: 0.6, seconds: 0.9))
        #expect(bench.setup.training == .learning(pass: 1, of: 8, secondsLeft: nil))       // one pass is not a measure
        bench.setup.training(.learning(pass: 4, of: 8, loss: 0.2, seconds: 2.0))
        #expect(bench.setup.training == .learning(pass: 4, of: 8, secondsLeft: 2.0))       // 0.5 s a pass, 4 to go

        bench.setup.training(.failed("signal 6"))
        #expect(bench.setup.training == .failed(reason: "signal 6", attempts: 1))
        bench.setup.retryTraining()
        bench.setup.training(.failed("signal 6 again"))
        #expect(bench.setup.training == .failed(reason: "signal 6 again", attempts: 2))
        #expect(bench.setup.info == nil)

        bench.setup.retryTraining()
        try bench.stageModel()
        bench.setup.training(.finished(bench.info()))
        #expect(bench.setup.training == .done)
        #expect(bench.setup.info == bench.info())
        #expect(bench.parts.store.info() == bench.info())
        bench.setup.close()
    }

    // MARK: The test

    @Test("A test that fails leaves the choice to you; using the model anyway is written down")
    func failedTest() throws {
        let bench = Bench()
        try bench.stageModel()
        try bench.parts.store.installStaged()
        bench.setup.open()
        #expect(bench.setup.step == .proof)
        #expect(bench.monitor.setupStage == .testing)
        bench.painted.stop()
        for index in 0..<30 { bench.setup.apply(frame(time: Double(index) / 30)) }

        bench.setup.startTest()
        #expect(bench.setup.proof == .running)
        // Ten ticks by hand, six of them answered.
        for tick in 0..<ProofTest.ticks {
            var ticked = frame(time: 10 + Double(tick) * 1.5)
            ticked.tick = true
            bench.setup.apply(ticked)
            if tick < 6 {
                var blinked = frame(time: 10.5 + Double(tick) * 1.5)
                blinked.blink = Blink(start: 10.35 + Double(tick) * 1.5, end: 10.5 + Double(tick) * 1.5)
                bench.setup.apply(blinked)
            }
        }
        bench.setup.testEnded()
        #expect(bench.setup.proof == .finished(ProofTest.Result(found: 6, of: 10, extra: 0)))
        #expect(bench.parts.store.info()?.proof?.found == 6 && bench.parts.store.info()?.isAccepted == false)

        bench.setup.finish()                                             // not accepted: finishing does nothing
        #expect(bench.setup.step == .proof)
        // One failure is often a missed tick: it is counted, and a second one in a row
        // is what makes "Record One More" the first choice.
        #expect(bench.setup.failedTests == 1)
        bench.setup.testAgain()
        #expect(bench.setup.proof == .ready)
        bench.setup.testEnded()                                          // no tick answered
        #expect(bench.setup.failedTests == 2)
        bench.setup.recordOneMore()
        #expect(bench.setup.step == .record && bench.setup.targetSessions == 1 && bench.setup.failedTests == 0)

        bench.setup.close()
        bench.setup.open()                                               // still waiting for its test
        #expect(bench.setup.step == .proof)
        bench.setup.useAnyway()
        #expect(bench.setup.step == .done)
        #expect(bench.parts.store.info()?.isAccepted == true && bench.parts.store.info()?.proof?.found == 0)
        bench.setup.close()
    }

    @Test("Closing before the test of a model trained again brings back the model that was in use")
    func closingKeepsTheModelInUse() throws {
        let bench = Bench()
        try bench.stageModel()
        try bench.parts.store.installStaged()
        try bench.parts.store.setProof(ModelInfo.Proof(found: 10, of: 10, extra: 0, on: Date(), accepted: true))
        try bench.stageModel()
        try bench.parts.store.installStaged()                            // trained again: not tested yet
        #expect(bench.parts.store.info()?.isAccepted == false && bench.parts.store.hasPrevious)

        bench.setup.open()
        #expect(bench.setup.step == .proof && bench.setup.hasPrevious)
        bench.setup.close()
        #expect(bench.parts.store.info()?.isAccepted == true && !bench.parts.store.hasPrevious)
    }

    // MARK: All of it

    @Test("The whole setup on painted eyes: two sessions recorded, a model trained, ten blinks counted",
          .enabled(if: EyeTrainer.isAvailable && ProcessInfo.processInfo.environment["CI"] == nil,
                   "no graphics processor to train on, or a machine it was not tried on"))
    func wholeSetup() async throws {
        let bench = Bench()
        let setup = bench.setup
        setup.open()
        #expect(setup.step == .welcome)
        setup.begin()
        #expect(bench.monitor.preferences.welcomed)

        await wait(5, for: "a steady face") { setup.canLeaveCameraCheck }
        setup.cameraLooksRight()
        for session in 1...2 {
            await wait(5, for: "a face before session \(session)") { setup.canStartSession }
            setup.startSession()
            await wait(30, for: "the end of session \(session)") { !setup.sessionRunning }
            #expect(setup.sessions.count == session, "\(setup.sessionNote ?? "no note")")
        }
        #expect(setup.enoughSessions)
        let pictures = setup.sessions.reduce(0) { $0 + $1.pictures }
        #expect(pictures >= bench.parts.pace.fullSessionPictures * 2 * 7 / 10)

        setup.train()
        await wait(120, for: "the training") {
            if case .failed = setup.training { return true }
            return setup.training == .done
        }
        #expect(setup.training == .done)
        let info = try #require(setup.info)
        #expect(info.pictures == pictures && info.sessions.count == 2)
        #expect(!setup.alteredSamples.isEmpty)

        setup.beginProof()
        await wait(5, for: "a face before the test") { setup.canStartTest }
        setup.startTest()
        await wait(40, for: "the end of the test") { if case .finished = setup.proof { return true } else { return false } }
        guard case .finished(let result) = setup.proof else { return }
        #expect(result.found == ProofTest.ticks, "\(result.found) of \(result.of), \(result.extra) more")

        setup.finish()
        #expect(setup.step == .done)
        #expect(bench.parts.store.info()?.isAccepted == true)
        #expect(ModelSource.resolve(store: bench.parts.store, given: nil, builtIn: bench.base) != .none)
        await wait(2, for: "the app leaving setup") { bench.monitor.setupStage == nil }
        setup.close()
    }
}

/// The app with no model, and the choice between several.
@MainActor
@Suite("Which model the app uses", .serialized)
struct ModelSourceTests {

    private func store() -> ModelStore {
        ModelStore(base: FileManager.default.temporaryDirectory.appendingPathComponent("blink-model-tests-\(UUID().uuidString)", isDirectory: true))
    }

    private func install(in store: ModelStore, accepted: Bool) throws {
        try store.prepareStaging()
        try EyeNetWeights(flat: [Float](repeating: 0, count: 60_289)).write(to: store.staging.appendingPathComponent(ModelStore.weightsName))
        try ModelInfo(trainedOn: Date(), sessions: ["a"], openPictures: 100, closedPictures: 100, passes: 30, seconds: 5, lastLoss: 0.01,
                      rightOnOwnPictures: 200, largestDifference: 0).write(to: store.staging.appendingPathComponent(ModelStore.infoName))
        try store.installStaged()
        if accepted { try store.setProof(ModelInfo.Proof(found: 9, of: 10, extra: 0, on: Date(), accepted: true)) }
    }

    @Test("Named at launch first, then trained here once its setup is finished, then built in, then none")
    func order() throws {
        let store = store()
        defer { try? store.delete() }
        let nowhere = store.base.appendingPathComponent("no-such-model")
        let builtIn = FileManager.default.temporaryDirectory          // any folder that exists
        let named = URL(fileURLWithPath: "/tmp/EyeNet.mlmodelc")

        #expect(ModelSource.resolve(store: store, given: nil, builtIn: nowhere) == .none)
        #expect(ModelSource.resolve(store: store, given: nil, builtIn: builtIn) == .builtIn(builtIn))

        try install(in: store, accepted: false)                       // trained, its test not taken
        #expect(ModelSource.resolve(store: store, given: nil, builtIn: nowhere) == .none)
        #expect(ModelSource.resolve(store: store, given: nil, builtIn: builtIn) == .builtIn(builtIn))

        try install(in: store, accepted: true)
        guard case .trainedHere(let info) = ModelSource.resolve(store: store, given: nil, builtIn: builtIn) else {
            Issue.record("the model trained here was not chosen")
            return
        }
        #expect(info.proof?.found == 9)
        #expect(try ModelSource.trainedHere(info).judge(store: store) != nil)
        #expect(ModelSource.resolve(store: store, given: named, builtIn: builtIn) == .given(named))
        #expect(try ModelSource.none.judge(store: store) == nil)
    }

    @Test("With no model the app waits for its setup, the camera untouched, and says what setup is doing")
    func waitsForSetup() async {
        let store = store()
        let model = MonitorModel(preferences: .temporary(), history: HistoryController(store: SampleData.scratchHistory()), modelStore: store)
        await model.start()
        #expect(model.lifecycle == .needsSetup)
        #expect(model.status() == .needsSetup)
        #expect(model.modelSource == .none)

        model.enterSetup(.training)
        #expect(model.status() == .settingUp(.training))
        var update = MonitorUpdate()
        update.live.faceFound = true
        model.apply(update)                                           // nothing is counted meanwhile
        #expect(!model.live.faceFound)
        model.leaveSetup()
        #expect(model.status() == .needsSetup)
    }
}
