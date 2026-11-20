import Foundation
import Combine
import Testing
import BlinkCore
@testable import BlinkMonitor

/// The app's own model, without a camera: started from a state, fed updates by hand.
@MainActor
@Suite("The app's model", .serialized)
struct ModelTests {

    private func running() -> MonitorModel {
        MonitorModel(preferences: .temporary(), history: HistoryController(store: SampleData.scratchHistory()),
                     initial: MonitorModel.InitialState())
    }

    private func frame(face: Bool = true, rate: Double? = 13, event: BlinkDetector.Event? = nil) -> MonitorUpdate {
        var update = MonitorUpdate()
        update.live.faceFound = face
        update.live.counters.ratePerMinute = rate
        update.event = event
        return update
    }

    // MARK: Pause

    @Test("A timed pause says when it ends, and is over at that moment whatever the timer does")
    func timedPause() {
        let model = running()
        let now = Date()
        model.pause(for: .fifteenMinutes, now: now)
        #expect(model.isPaused)
        #expect(model.status(now: now.addingTimeInterval(60)) == .paused(until: now.addingTimeInterval(900)))
        #expect(model.status(now: now.addingTimeInterval(901)) != .paused(until: now.addingTimeInterval(900)))
        model.resume()
        #expect(!model.isPaused)
    }

    @Test("Frames that arrive during a pause are not shown")
    func pauseIgnoresFrames() {
        let model = running()
        model.pause(for: .untilResumed)
        model.apply(frame(rate: 40))
        #expect(model.live.counters.ratePerMinute == nil)
        model.resume()
    }

    // MARK: A camera that stops sending pictures

    @Test("No picture for more than five seconds is said, and the last number is not left on screen")
    func silentCamera() {
        let model = running()
        let start = Date()
        model.apply(frame(), now: start)
        #expect(model.status(now: start) == .watching(rate: 13))

        model.checkCamera(now: start.addingTimeInterval(3))
        #expect(!model.cameraSilent)

        model.checkCamera(now: start.addingTimeInterval(6))
        #expect(model.cameraSilent)
        #expect(model.status(now: start.addingTimeInterval(6)) == .cameraSilent)
        #expect(model.live.counters.ratePerMinute == nil)

        // The pictures come back: so does the status, by itself.
        model.apply(frame(), now: start.addingTimeInterval(8))
        #expect(!model.cameraSilent)
        #expect(model.status(now: start.addingTimeInterval(8)) == .watching(rate: 13))
    }

    @Test("A paused camera is not a silent one")
    func pausedIsNotSilent() {
        let model = running()
        let start = Date()
        model.apply(frame(), now: start)
        model.pause(for: .untilResumed, now: start)
        model.checkCamera(now: start.addingTimeInterval(60))
        #expect(!model.cameraSilent)
        model.resume()
    }

    // MARK: Blinks

    @Test("Each counted blink is announced once: the menu-bar eye blinks back")
    func blinkAnnounced() {
        let model = running()
        var announced = 0
        let listening = model.blinked.sink { announced += 1 }
        model.apply(frame(event: .blink(Blink(start: 1, end: 1.15))))
        model.apply(frame())
        model.apply(frame(event: .longClosure(seconds: 2)))        // not a blink
        #expect(announced == 1)
        listening.cancel()
    }

    @Test("A blink break counts the events of the model it belongs to, slow blinks included")
    func blinkBreakCounts() {
        let model = running()
        model.blinkBreak.start()
        model.apply(frame(event: .blink(Blink(start: 1, end: 1.15))))
        model.apply(frame(event: .longClosure(seconds: 1.1)))
        #expect(model.blinkBreak.exercise?.count == 2)
        model.blinkBreak.stop()
    }
}

/// The demo: made-up eyes, counted by the real code.
@MainActor
@Suite("The demo", .serialized)
struct DemoTests {

    /// Runs `seconds` of made-up frames through a real pipeline; returns what it reported.
    private func run(seconds: Double, pace: DemoEyes.Pace) -> [MonitorUpdate] {
        var eyes = DemoEyes()
        eyes.pace = pace
        let pipeline = MonitorPipeline()
        pipeline.setLiveView(true)                 // report every frame
        var updates: [MonitorUpdate] = []
        pipeline.onUpdate = { updates.append($0) }
        for frame in 0..<Int(seconds * 30) {
            let time = 1000 + Double(frame) / 30
            pipeline.process(eyes.reading(at: time), time: time)
        }
        return updates
    }

    @Test("Made-up eyes blink like a person at a screen: about 13 times a minute")
    func usualPace() throws {
        let updates = run(seconds: 600, pace: .usual)
        let blinks = updates.filter { if case .blink = $0.event { return true } else { return false } }.count
        #expect((100...160).contains(blinks), "\(blinks) blinks in ten minutes")
        let rate = try #require(updates.last?.live.counters.ratePerMinute)
        #expect((8...18).contains(rate))
        #expect(updates.allSatisfy { $0.live.faceFound && $0.live.eyeAnswers.count == 2 })
    }

    @Test("During a blink break they do the exercise: slow blinks, which only the break counts")
    func exercisePace() {
        let updates = run(seconds: 30, pace: .exercise)
        var exercise = BlinkBreak()
        var counted = 0
        for update in updates {
            guard let event = update.event else { continue }
            exercise.record(event)
            if case .blink = event { counted += 1 }
        }
        #expect(exercise.isDone, "\(exercise.count) of \(exercise.target) in 30 s")
        #expect(counted == 0)
    }

    @Test("The pipeline reports exactly the events the blink detector finds, in the same order")
    func pipelineCountsWhatTheDetectorCounts() {
        // The same stream twice: once through the pipeline the app uses, once through the
        // detector alone. Splitting the pipeline to make room for the demo must not have
        // changed what is counted.
        var eyes = DemoEyes(seed: 7)
        var readings: [(reading: FrameReading, time: Double)] = []
        for frame in 0..<(300 * 30) {
            let time = 500 + Double(frame) / 30
            if frame == 4000 { eyes.pace = .exercise }
            if frame == 5500 { eyes.pace = .usual }
            var reading = eyes.reading(at: time)
            if (6000..<6040).contains(frame) { reading = FrameReading() }      // the face is lost for a moment
            readings.append((reading, time))
        }

        let pipeline = MonitorPipeline()
        var reported: [BlinkDetector.Event] = []
        pipeline.onUpdate = { if let event = $0.event { reported.append(event) } }
        var detector = BlinkDetector()
        var expected: [BlinkDetector.Event] = []
        for (reading, time) in readings {
            pipeline.process(reading, time: time)
            if let event = detector.update(time: time, closed: reading.closed) { expected.append(event) }
        }
        #expect(reported == expected)
        #expect(expected.count > 60, "\(expected.count) events in five minutes")
    }

    @Test("The same made-up eyes at every run")
    func deterministic() {
        var a = DemoEyes(), b = DemoEyes()
        let times = (0..<900).map { 50 + Double($0) / 30 }
        #expect(times.map { a.reading(at: $0).closed } == times.map { b.reading(at: $0).closed })
    }

    @Test("The demo never writes to the user's own history")
    func demoKeepsItsDataApart() {
        let model = SampleData.demoModel()
        #expect(model.isDemo)
        #expect(model.history.store.file != HistoryStore.defaultFile)
        #expect(model.history.store.file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!model.history.minutes.isEmpty)
        #expect(!model.loginItem.available)
        #expect(!model.canCapture)
    }
}

/// Rules about the source itself.
@Suite("The app's source")
struct SourceTests {

    /// The project folder (two levels above this file's folder).
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("No window keeps the moment it was created as 'now'")
    func noStoredNow() throws {
        // `var now = Date()` as a property of a view is the moment the VIEW was made - and a
        // view is made once. That froze the panel's clock at the app's launch (see Moment).
        // A property is declared four spaces in; a local constant inside a function, eight.
        let stored = try Regex(#"^    (var|let) \w+(: Date)? = Date\(\)"#).anchorsMatchLineEndings()
        var offenders: [String] = []
        for folder in ["Sources/BlinkMonitor", "Sources/BlinkRecorder", "Sources/BlinkUI"] {
            let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains(stored) { offenders.append(file.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "a stored Date() in: \(offenders)")
    }
}
