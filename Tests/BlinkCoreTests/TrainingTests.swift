import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import BlinkCore

/// The model the app trains itself: its weights file, the network that runs it, the
/// alterations, the trainer, and the whole training from sessions on disk.
///
/// No real eye is needed: the trainer is given painted eyes (`PaintedEye`), a task whose
/// right answer is known and that it must learn in seconds.
@Suite("Training in the app")
struct TrainingTests {

    /// Weights that make the network answer one known number: every detector is zero, so
    /// only the last bias is left.
    private func silentWeights(bias: Float) throws -> EyeNetWeights {
        var flat = [Float](repeating: 0, count: EyeNetWeights.sizes.reduce(0, +))
        flat[flat.count - 1] = bias
        return try EyeNetWeights(flat: flat)
    }

    // MARK: The weights file

    @Test("The weights file comes back as it was written, and is 241 KB")
    func weightsFile() throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try PrivateFolder.create(at: folder)
        var random = SeededRandom(seed: 3)
        let weights = try EyeNetWeights(flat: (0..<60_289).map { _ in random.uniform(-1, 1) })

        let file = folder.appendingPathComponent("eyenet.weights")
        try weights.write(to: file)
        #expect(try EyeNetWeights(contentsOf: file) == weights)
        #expect(try Data(contentsOf: file).count == 8 + 60_289 * 4)
        #expect(weights.kernels.map(\.count) == [144, 4608, 18_432, 36_864])
        #expect(weights.biases.map(\.count) == [16, 32, 64, 64])
    }

    @Test("A file that is not a whole eye model is refused")
    func brokenWeightsFile() throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try PrivateFolder.create(at: folder)
        let whole = folder.appendingPathComponent("whole.weights")
        try silentWeights(bias: 0).write(to: whole)
        let data = try Data(contentsOf: whole)

        let cut = folder.appendingPathComponent("cut.weights")
        try data.prefix(data.count / 2).write(to: cut)
        #expect(throws: EyeNetWeights.WeightsError.self) { try EyeNetWeights(contentsOf: cut) }

        let other = folder.appendingPathComponent("other.weights")
        try (Data("SOMETHIN".utf8) + data.dropFirst(8)).write(to: other)
        #expect(throws: EyeNetWeights.WeightsError.self) { try EyeNetWeights(contentsOf: other) }

        #expect(throws: EyeNetWeights.WeightsError.self) { try EyeNetWeights(flat: [1, 2, 3]) }
        var broken = try silentWeights(bias: 0).flat
        broken[10] = .nan
        #expect(throws: EyeNetWeights.WeightsError.self) { try EyeNetWeights(flat: broken) }
    }

    // MARK: The network in Swift

    @Test("With every detector at zero, the answer is the last bias squeezed into 0...1")
    func knownAnswer() throws {
        let picture = try #require(PaintedEye().buffer())
        let answer = try EyeNetwork(weights: silentWeights(bias: 1.5)).closedProbability(of: picture)
        #expect(abs(answer - 1 / (1 + exp(-1.5))) < 1e-6)
    }

    @Test("Brighter or flatter, the same picture gets the same answer")
    func brightnessDoesNotMatter() throws {
        var random = SeededRandom(seed: 11)
        let network = EyeNetwork(weights: try EyeNetWeights(flat: (0..<60_289).map { _ in random.uniform(-0.2, 0.2) }))
        let gray = try #require(PaintedEye(openness: 0.8).buffer().flatMap(TrainingSet.gray(of:)))
        // Half the contrast, and lifted: what a dimmer lamp does to a picture.
        let dimmer = gray.map { $0 * 0.5 + 0.2 }
        let first = network.closedProbability(ofGray: gray), second = network.closedProbability(ofGray: dimmer)
        #expect(abs(first - second) < 1e-3, "\(first) and \(second)")
    }

    @Test("A pixel buffer and its brightness values get the same answer, and red counts less than green")
    func bufferAndGray() throws {
        var random = SeededRandom(seed: 5)
        let network = EyeNetwork(weights: try EyeNetWeights(flat: (0..<60_289).map { _ in random.uniform(-0.2, 0.2) }))
        let buffer = try #require(PaintedEye(openness: 0).buffer())
        let gray = try #require(TrainingSet.gray(of: buffer))
        #expect(abs(try network.closedProbability(of: buffer) - network.closedProbability(ofGray: gray)) < 1e-6)

        // The frame painted by the test helper is red on top and blue below.
        let frame = Fixture.frame(width: 64, height: 64, target: CGRect(x: 0, y: 0, width: 64, height: 64))
        let colours = try #require(TrainingSet.gray(of: frame))
        #expect(abs(colours[0] - 0.299) < 0.001)                 // pure red
        #expect(abs(colours[64 * 63] - 0.114) < 0.001)           // pure blue
    }

    @Test("A picture read from disk gives the numbers of the pixel buffer the model is handed when it runs")
    func fileAndBuffer() throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try PrivateFolder.create(at: folder)
        let eye = PaintedEye(openness: 0.7, tilt: 0.2, gaze: CGPoint(x: 0.4, y: -0.3))
        let file = folder.appendingPathComponent("eye.png")
        #expect(PNGFile.write(try #require(eye.image()), to: file))

        let fromFile = try #require(TrainingSet.gray(contentsOf: file))
        let fromBuffer = try #require(eye.buffer().flatMap(TrainingSet.gray(of:)))
        #expect(fromFile == fromBuffer)
        // And through the path the Core ML model's own test uses for pictures on disk.
        let reread = try #require(PNGFile.read(file).flatMap(EyeCropper.buffer(from:)).flatMap(TrainingSet.gray(of:)))
        #expect(fromFile == reread)
        #expect(TrainingSet.gray(contentsOf: folder.appendingPathComponent("missing.png")) == nil)
    }

    @Test("A picture of the wrong size is refused, not silently resized")
    func wrongSize() throws {
        let network = EyeNetwork(weights: try silentWeights(bias: 0))
        #expect(throws: EyeClassifier.ClassifierError.self) {
            try network.closedProbability(of: Fixture.frame(width: 128, height: 128))
        }
    }

    // MARK: Alterations and schedule

    @Test("An alteration is repeatable, stays a picture, and changes it")
    func alteration() throws {
        let gray = try #require(PaintedEye().buffer().flatMap(TrainingSet.gray(of:)))
        func altered(seed: UInt64) -> [Float] {
            var out = [Float](repeating: 0, count: gray.count), random = SeededRandom(seed: seed)
            PictureAlteration.apply(gray, into: &out, random: &random)
            return out
        }
        #expect(altered(seed: 1) == altered(seed: 1))
        #expect(altered(seed: 1) != altered(seed: 2))
        #expect(altered(seed: 1) != gray)
        for seed in 0..<20 { #expect(altered(seed: UInt64(seed)).allSatisfy { $0 >= 0 && $0 <= 1 }) }
    }

    @Test("The learning rate starts small, peaks at 0.002 after 30% of the steps, and ends at almost nothing")
    func schedule() {
        let total = 900
        #expect(abs(EyeTrainer.oneCycle(step: 0, total: total).rate - 0.00008) < 1e-9)
        #expect(abs(EyeTrainer.oneCycle(step: 269, total: total).rate - 0.002) < 1e-9)
        #expect(EyeTrainer.oneCycle(step: total - 1, total: total).rate < 1e-8)
        #expect(abs(EyeTrainer.oneCycle(step: 0, total: total).beta1 - 0.95) < 1e-9)
        #expect(abs(EyeTrainer.oneCycle(step: 269, total: total).beta1 - 0.85) < 1e-9)
        // A training of a handful of steps must not divide by zero.
        #expect(EyeTrainer.oneCycle(step: 0, total: 2).rate.isFinite)
        #expect(EyeTrainer.oneCycle(step: 1, total: 2).rate.isFinite)
    }

    // MARK: The trainer

    @Test("The trainer learns painted eyes in seconds, and the network that runs gives its answers",
          .enabled(if: Fixture.canTrain, "no graphics processor to train on, or a machine it was not tried on"))
    func learnsPaintedEyes() throws {
        func paint(_ count: Int, seed: UInt64) -> (gray: [Float], labels: [Float]) {
            var random = SeededRandom(seed: seed), gray: [Float] = [], labels: [Float] = []
            for index in 0..<count {
                let open = index % 2 == 0
                gray += PaintedEye.random(open: open, using: &random).buffer().flatMap(TrainingSet.gray(of:)) ?? []
                labels.append(open ? 0 : 1)
            }
            return (gray, labels)
        }
        let known = paint(256, seed: 1), unseen = paint(96, seed: 2)

        let trainer = try #require(EyeTrainer(seed: 1))
        var passes = 0
        let losses = trainer.train(images: known.gray, labels: known.labels, epochs: 10, seed: 1) { pass, _ in passes = pass }
        #expect(passes == 10)
        let (first, last) = (try #require(losses.first), try #require(losses.last))
        #expect(last < first)

        // Eyes it never saw.
        let answers = trainer.predict(images: unseen.gray, count: unseen.labels.count)
        let right = zip(answers, unseen.labels).filter { ($0 > 0.5) == ($1 > 0.5) }.count
        #expect(right >= 92, "\(right) of \(unseen.labels.count) unseen painted eyes right")

        // The same model twice: as it learned, and as the app will run it.
        let network = EyeNetwork(weights: try trainer.weights())
        var largest = 0.0
        unseen.gray.withUnsafeBufferPointer { pictures in
            for index in 0..<unseen.labels.count {
                let answer = network.closedProbability(ofGray: pictures.baseAddress! + index * EyeNetwork.pixels)
                largest = max(largest, abs(answer - Double(answers[index])))
            }
        }
        #expect(largest < Double(TrainingRun.largestDifferenceAllowed), "largest difference \(largest)")
    }

    // MARK: From sessions on disk

    @Test("The pictures to learn from: every session's, without the far eye of a turned head or a missing file")
    func trainingSet() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try Fixture.paintedSession(in: root, name: "20270101-090000", pictures: 4)
        try Fixture.paintedSession(in: root, name: "20270101-100000", pictures: 3, seed: 2)

        // By hand: one picture deleted, and one line of a head turned far to the right.
        try FileManager.default.removeItem(at: first.appendingPathComponent("open/p00_f000000_L.png"))
        let manifest = first.appendingPathComponent("manifest.csv")
        var text = try String(contentsOf: manifest, encoding: .utf8)
        text += "20270101-090000,painted,1,closed,turned,99,3.300,R,closed/p01_f000001_L.png,0,0,128,260.0,0.000,0.785,1920,1080\n"
        try text.write(to: manifest, atomically: true, encoding: .utf8)

        let entries = TrainingSet.list(root: root)
        #expect(entries.count == 7 + 6)
        #expect(entries.filter(\.closed).count == 4 + 3)
        #expect(Set(entries.map(\.session)) == ["20270101-090000", "20270101-100000"])
        #expect(TrainingSet.list(root: root, sessions: ["20270101-100000"]).count == 6)

        let set = TrainingSet.load(entries)
        #expect(set.count == 13 && set.gray.count == 13 * EyeNetwork.pixels)
        #expect(set.gray.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(TrainingSet.isFarEye(side: "R", yaw: 0.785) && TrainingSet.isFarEye(side: "L", yaw: -0.785))
        #expect(!TrainingSet.isFarEye(side: "L", yaw: 0.785) && !TrainingSet.isFarEye(side: "R", yaw: 0.2))
    }

    @Test("A whole training: from a session on disk to a model that is installed and answers",
          .enabled(if: Fixture.canTrain, "no graphics processor to train on, or a machine it was not tried on"))
    func wholeTraining() throws {
        let base = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let sessions = base.appendingPathComponent("sessions")
        try Fixture.paintedSession(in: sessions, name: "20270101-090000", pictures: 100)
        let store = ModelStore(base: base)
        try store.prepareStaging()

        var said: [TrainingProgress] = []
        let info = try #require(TrainingRun.run(sessions: sessions, into: store.staging, passes: 8) { said.append($0) })
        #expect(info.openPictures == 100 && info.closedPictures == 100)
        #expect(info.sessions == ["20270101-090000"])
        #expect(info.rightOnOwnPictures >= 190)
        #expect(info.largestDifference <= TrainingRun.largestDifferenceAllowed)
        #expect(info.proof == nil && !info.isAccepted)
        #expect(said.last == .finished(info))
        #expect(said.contains(.checking))
        #expect(said.filter { if case .learning = $0 { return true } else { return false } }.count == 8)
        // Each word survives being a line of text between two processes.
        for word in said { #expect(TrainingProgress(line: word.line) == word) }

        #expect(store.info() == nil)                     // nothing is in use until it is installed
        try store.installStaged()
        #expect(store.info() == info)
        let network = try store.network()
        #expect(try network.closedProbability(of: try #require(PaintedEye(openness: 0).buffer())) > 0.5)
        #expect(try network.closedProbability(of: try #require(PaintedEye(openness: 1).buffer())) < 0.5)
    }

    @Test("Too few pictures is said, and nothing is written")
    func tooFewPictures() throws {
        let base = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try Fixture.paintedSession(in: base.appendingPathComponent("sessions"), name: "20270101-090000", pictures: 5)
        var said: [TrainingProgress] = []
        let info = TrainingRun.run(sessions: base.appendingPathComponent("sessions"), into: base.appendingPathComponent("out")) { said.append($0) }
        #expect(info == nil)
        guard case .failed(let reason) = said.last else {
            Issue.record("the training did not say it failed")
            return
        }
        #expect(reason.contains("too few"))
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("out").path))
    }

    // MARK: The model's place on disk

    @Test("A new model takes the place of the old one, which can be put back; deleting removes both")
    func modelStore() throws {
        let base = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ModelStore(base: base)
        #expect(store.info() == nil && !store.hasPrevious)

        func stage(bias: Float, pictures: Int) throws {
            try store.prepareStaging()
            try silentWeights(bias: bias).write(to: store.staging.appendingPathComponent(ModelStore.weightsName))
            try ModelInfo(trainedOn: Date(timeIntervalSince1970: 1_800_000_000), sessions: ["s"], openPictures: pictures,
                          closedPictures: pictures, passes: 30, seconds: 10, lastLoss: 0.01, rightOnOwnPictures: pictures * 2,
                          largestDifference: 0).write(to: store.staging.appendingPathComponent(ModelStore.infoName))
        }
        try stage(bias: 1, pictures: 100)
        try store.installStaged()
        #expect(store.info()?.pictures == 200)
        try store.setProof(ModelInfo.Proof(found: 10, of: 10, extra: 0, on: Date(timeIntervalSince1970: 1_800_000_100), accepted: true))
        #expect(store.info()?.isAccepted == true)

        // A second training: the first model is kept once.
        try stage(bias: 2, pictures: 300)
        try store.installStaged()
        #expect(store.info()?.pictures == 600 && store.info()?.isAccepted == false && store.hasPrevious)
        try store.restorePrevious()
        #expect(store.info()?.pictures == 200 && store.info()?.isAccepted == true && !store.hasPrevious)

        // A folder that does not hold a whole model replaces nothing.
        try store.prepareStaging()
        #expect(throws: (any Error).self) { try store.installStaged() }
        #expect(store.info()?.pictures == 200)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.staging.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)

        try store.delete()
        #expect(store.info() == nil && !FileManager.default.fileExists(atPath: store.staging.path))
    }
}

/// Recording a session and testing a model, on painted eyes: what the setup window drives.
@Suite("Sessions and the test at the end of setup")
struct SessionTests {

    /// A stand-in for the model: an eye is "closed" when its picture has no dark pupil.
    private struct PupilJudge: EyeJudging {
        func closedProbability(of eye: CVPixelBuffer) throws -> Double {
            guard let gray = TrainingSet.gray(of: eye) else { return 0.5 }
            return gray.filter { $0 < 0.08 }.count > 20 ? 0.02 : 0.98
        }
    }

    private func frame(openness: Double) -> FoundEyes {
        let square = CGRect(x: 800, y: 400, width: 128, height: 128)
        let left = EyeRegion(side: .imageLeft, cropRect: square, center: CGPoint(x: square.midX, y: square.midY))
        let right = EyeRegion(side: .imageRight, cropRect: square.offsetBy(dx: 260, dy: 0), center: CGPoint(x: square.midX + 260, y: square.midY))
        let located = LocatedEyes(faceRect: .zero, left: left, right: right, interocularDistance: 260, roll: 0, yaw: nil)
        let crops = [left, right].compactMap { region in
            PaintedEye(openness: openness, noseOnRight: region.side == .imageLeft).buffer().map { EyeCrop(picture: $0, of: region) }
        }
        return FoundEyes(crops: crops, of: located)
    }

    @Test("A session holds 960 pictures at the usual pace, and under 70% of it is recorded again")
    func sessionCheck() {
        #expect(SessionScript.phases.count == 16)
        #expect(SessionScript.phases.filter { $0.label == .open }.count == 8)
        #expect(SessionPace.usual.fullSessionPictures == 960)
        #expect(SessionCheck.isComplete(pictures: 672) && !SessionCheck.isComplete(pictures: 671))
        #expect(SessionCheck.isComplete(pictures: SessionPace.painted.fullSessionPictures, pace: .painted))
        #expect(SessionScript.sessionName(at: Date(timeIntervalSince1970: 0)).count == 15)
    }

    @Test("Pictures are saved only while a pose is being recorded, with the pose's label, in the recorder's format")
    func recording() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = SessionPipeline(pace: .painted)
        var frames: [SessionFrame] = []
        pipeline.onUpdate = { frames.append($0) }
        let size = CGSize(width: 1920, height: 1080)

        pipeline.process(frame(openness: 1), frameSize: size, time: 1.0)           // before the session: shown, not saved
        let writer = try SessionWriter(root: root, session: "20270101-090000", condition: "")
        pipeline.setRecording(SessionPipeline.Recording(writer: writer, phaseIndex: 1, phase: SessionScript.phases[1]))
        pipeline.process(frame(openness: 0), frameSize: size, time: 1.033)
        pipeline.process(frame(openness: 0), frameSize: size, time: 1.067)
        pipeline.setRecording(nil)
        pipeline.process(frame(openness: 1), frameSize: size, time: 1.1)
        pipeline.process(nil, frameSize: size, time: 1.133)                        // nobody there

        #expect(frames.map(\.savedClosed) == [0, 2, 2, 0, 0])
        #expect(frames.map(\.savedOpen) == [0, 0, 0, 0, 0])
        #expect(frames.map(\.faceFound) == [true, true, true, true, false])
        #expect(frames[0].leftCrop != nil && frames[0].rightCrop != nil && frames[0].cropSide == 128)
        let level = try #require(frames[0].brightness)
        #expect(level > 100 && level < 230)

        let session = try #require(SessionStore.sessions(in: root).first)
        #expect(session.name == "20270101-090000" && session.open == 0 && session.closed == 4)
        let lines = try String(contentsOf: writer.folder.appendingPathComponent("manifest.csv"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.first == SessionWriter.header)
        #expect(lines.count == 5 && lines[1].hasPrefix("20270101-090000,,1,closed,gentle,2,1.033,L,closed/p01_f000002_L.png,"))
        #expect(TrainingSet.list(root: root).count == 4)
        #expect(SessionStore.bytes(under: root) > 1000)
    }

    @Test("With a model set, blinks are counted and ticks are passed on")
    func testing() {
        let pipeline = SessionPipeline(pace: .painted)
        var frames: [SessionFrame] = []
        pipeline.onUpdate = { frames.append($0) }
        pipeline.setJudge(PupilJudge())
        let size = CGSize(width: 1920, height: 1080)

        // Three seconds at 30 frames a second, a tick at 1.0 s and a four-frame blink after it.
        for index in 0..<90 {
            if index == 30 { pipeline.markTick() }
            pipeline.process(frame(openness: (38..<42).contains(index) ? 0 : 1), frameSize: size, time: Double(index) / 30)
        }
        #expect(frames.filter(\.tick).map(\.time) == [1.0])
        let blinks = frames.compactMap(\.blink)
        #expect(blinks.count == 1)
        #expect(abs((blinks.first?.start ?? 0) - 38.0 / 30) < 0.001)
        #expect(frames[39].eyesClosed && !frames[50].eyesClosed)
        #expect(frames.allSatisfy { $0.savedOpen == 0 && $0.savedClosed == 0 })

        // The model taken away again: nothing is judged.
        pipeline.setJudge(nil)
        pipeline.process(frame(openness: 0), frameSize: size, time: 3.1)
        #expect(frames.last?.closed == nil)
    }

    @Test("The test's score: one blink answers one tick; a second one, or one before the first tick, does not")
    func proofScore() {
        var test = ProofTest()
        test.blink(Blink(start: 9.0, end: 9.15))                    // before anything was asked
        for tick in 0..<ProofTest.ticks {
            let time = 10 + Double(tick) * ProofTest.secondsBetweenTicks
            test.tick(at: time)
            if tick == 3 { continue }                               // a tick that got no blink
            // The fifth blink comes a little early: people go with the rhythm.
            test.blink(Blink(start: time + (tick == 5 ? -0.2 : 0.35), end: time + 0.5))
            if tick == 7 { test.blink(Blink(start: time + 0.9, end: time + 1.05)) }     // a second blink after one tick
        }
        #expect(test.isComplete)
        #expect(test.answered == [true, true, true, false, true, true, true, true, true, true])
        #expect(test.result == ProofTest.Result(found: 9, of: 10, extra: 1))
        #expect(test.result.passed)
        #expect(!ProofTest.Result(found: 7, of: 10, extra: 0).passed && ProofTest.Result(found: 8, of: 10, extra: 0).passed)
        #expect(ProofTest().result == ProofTest.Result(found: 0, of: 10, extra: 0))
    }

    @Test("Without a model the app says so; while setup works, that is what it says")
    func statuses() {
        func status(_ lifecycle: Lifecycle, setup: MonitorStatus.SetupStage? = nil) -> MonitorStatus {
            MonitorStatus(lifecycle: lifecycle, setup: setup, faceFound: true, rate: 13, recentLowRate: nil)
        }
        #expect(status(.needsSetup) == .needsSetup)
        #expect(status(.needsSetup, setup: .recording) == .settingUp(.recording))
        #expect(status(.running, setup: .testing) == .settingUp(.testing))       // adding a session later
        #expect(status(.running) == .watching(rate: 13))
        #expect(status(.cameraRefused, setup: .checkingCamera) == .cameraRefused)
        #expect(!MonitorStatus.needsSetup.isCameraOn && !MonitorStatus.settingUp(.training).isCameraOn)
    }
}
