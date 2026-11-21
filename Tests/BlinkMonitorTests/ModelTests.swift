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

/// The choices the app remembers.
@MainActor
@Suite("Preferences")
struct PreferencesTests {

    /// A store of its own for one test, emptied before and after.
    private func withStore(_ body: (UserDefaults) -> Void) {
        let name = "local.blinkmonitor.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        defer { store.removePersistentDomain(forName: name) }
        body(store)
    }

    @Test("An install starts at the floor the experiment gives, welcomed or not")
    func startingFloor() {
        withStore { store in
            let first = Preferences(defaults: store)
            #expect(first.floor == PublishedRates.startingFloor && first.limit == PublishedRates.startingFloor)
            first.welcomed = true
            #expect(Preferences(defaults: store).floor == PublishedRates.startingFloor)
        }
    }

    @Test("The floor can be set as low as 1, so that a limit can follow someone who blinks very little")
    func lowestFloor() {
        #expect(Preferences.floorChoices.lowerBound == 1)
        #expect(Preferences.floorChoices.contains(PublishedRates.startingFloor))

        withStore { store in
            // Somebody who makes 1.6 complete blinks a minute at a screen, floor at its lowest.
            let preferences = Preferences(defaults: store)
            preferences.reference = Reference(rate: 1.6, measuredOn: Date(timeIntervalSince1970: 1_800_000_000), minutes: 200)
            #expect(Baseline.limitAboveUsual(reference: preferences.reference, limit: preferences.limit), "at the starting floor")
            preferences.floor = Preferences.floorChoices.lowerBound
            #expect(preferences.limit == 1)
            #expect(!Baseline.limitAboveUsual(reference: preferences.reference, limit: preferences.limit))
            // The choice is kept.
            #expect(Preferences(defaults: store).floor == 1)
        }
    }

    @Test("A floor somebody chose is never replaced")
    func chosenFloor() {
        withStore { store in
            store.set(8, forKey: "threshold")
            #expect(Preferences(defaults: store).floor == 8)
            store.set(true, forKey: "welcomed")
            #expect(Preferences(defaults: store).floor == 8)
        }
    }
}

/// What the app says about published studies: typical, never ideal.
@Suite("Words about the studies")
struct StudyWordsTests {

    private let positions: [(Double, StudyRange.Position)] = [(0.9, .below), (11.8, .inside), (21.3, .above)]

    @Test("Wherever a week falls, the sentence gives the range and never calls a rate ideal, healthy or normal")
    func comparisonSentences() {
        let judgements = ["ideal", "healthy", "normal", "should", "too little", "too much", "warning"]
        for (rate, position) in positions {
            let sentence = PublishedRates.Comparison(rate: rate, position: position).sentence
            #expect(sentence.contains(PublishedRates.atScreen.span), "the range is missing: \(sentence)")
            #expect(sentence.contains(String(format: "%.1f", rate)))
            for word in judgements {
                #expect(!sentence.lowercased().contains(word), "'\(word)' in: \(sentence)")
            }
        }
        // Under the range, the likely reason is the counting, and the sentence says where to look.
        #expect(PublishedRates.Comparison(rate: 0.9, position: .below).sentence.contains("Live View"))
        // Above it, the ordinary reason is talking.
        #expect(PublishedRates.Comparison(rate: 21.3, position: .above).sentence.contains(PublishedRates.inConversation.span))
        #expect(PublishedRates.Comparison(rate: 11.8, position: .inside).sentence.contains("not a target"))
    }

    @Test("The ranges are written with one decimal, dropped when it is zero")
    func spans() {
        #expect(PublishedRates.atScreen.span == "1.4 to 14.4")
        #expect(PublishedRates.lookingAhead.span == "8 to 21")
        #expect(PublishedRates.inConversation.span == "10.5 to 32.5")
        #expect(PublishedRates.caption.contains("a target") && PublishedRates.caption.contains(PublishedRates.atScreen.source.name))
        #expect(PublishedRates.caption.contains(PublishedRates.experiment.source.name))
        #expect(PublishedRates.experiment.span == "10 worse, 20 fine")
    }

    @Test("A limit above the usual rate is explained, with a way out that exists")
    func limitAboveUsual() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let ordinary = PublishedRates.limitAboveUsual(reference: Reference(rate: 7.2, measuredOn: day, minutes: 200),
                                                      limit: 10, canLower: true)
        #expect(ordinary.contains("7.2") && ordinary.contains("limit of 10") && ordinary.contains("ordinary at a screen"))
        #expect(ordinary.contains("lower Never under"))

        // Under what studies report: the counting is the likely reason, not the person.
        let missed = PublishedRates.limitAboveUsual(reference: Reference(rate: 0.9, measuredOn: day, minutes: 200),
                                                    limit: 4, canLower: false)
        #expect(missed.contains("Live View") && !missed.contains("ordinary"))
        #expect(missed.contains("as low as it goes") && !missed.contains("lower Never under"))
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

    @Test("No window types a number that comes from a study: they are read from PublishedRates")
    func noStudyNumberInAView() throws {
        // The ends of the ranges that are not whole numbers, as a window would write them,
        // and the sentence the first version had in Settings, which had no source.
        let ends = PublishedRates.ranges.flatMap { [$0.lower, $0.upper] }.filter { $0 != $0.rounded() }
        #expect(ends.count >= 4)
        let figures = ends.map { String(format: "%.1f", $0) }
        // A figure standing alone: not the tail of 21.4, nor the head of 1.45.
        let typed = try Regex("(^|[^0-9.])(" + figures.map { $0.replacingOccurrences(of: ".", with: "\\.") }
            .joined(separator: "|") + ")($|[^0-9])").anchorsMatchLineEndings()
        var offenders: [String] = []
        for folder in ["Sources/BlinkMonitor", "Sources/BlinkRecorder", "Sources/BlinkUI"] {
            let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains(typed) || text.contains("15 to 20 times a minute") { offenders.append(file.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "a study's number typed in: \(offenders)")
    }
}
