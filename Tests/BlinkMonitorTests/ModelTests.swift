import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
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

    @Test("On Automatic, ten seconds without a picture and the app tries another camera, once; a chosen camera is kept")
    func cameraFallback() {
        let own = CameraOption(id: "own", name: "FaceTime HD Camera", builtIn: true)
        let desk = CameraOption(id: "desk", name: "Studio Display Camera", builtIn: false)
        let model = running()
        model.cameraOptions = { [own, desk] }
        let start = Date()
        model.apply(frame(), now: start)
        model.checkCamera(now: start.addingTimeInterval(6))
        #expect(model.cameraSilent && model.cameraMovedTo == nil, "silent, but not for ten seconds yet")
        model.checkCamera(now: start.addingTimeInterval(11))
        #expect(model.cameraMovedTo == "Studio Display Camera")
        #expect(CameraWords.moved(to: "Studio Display Camera").contains("test it again"))

        // A camera chosen by hand: the note goes, and silence no longer moves anything.
        model.setCamera("own")
        #expect(model.cameraMovedTo == nil && model.preferences.cameraID == "own")
        model.checkCamera(now: Date().addingTimeInterval(60))
        #expect(model.cameraMovedTo == nil)
        model.setCamera(nil)
        #expect(model.preferences.cameraID == nil)
    }

    @Test("Rest on battery turns counting off and back by itself; Resume counts anyway until the Mac is plugged in")
    func restOnBattery() {
        let model = running()
        var onBattery = false
        model.powerFacts = { (onBattery, false) }
        let start = Date()
        model.apply(frame(), now: start)
        model.preferences.pauseOnBattery = true
        model.checkEnergy()
        #expect(model.energyHold == nil && model.status(now: start) == .watching(rate: 13))

        onBattery = true
        model.checkEnergy()
        #expect(model.energyHold == .battery && model.showsResume && !model.isPaused)
        #expect(model.status(now: start) == .paused(until: nil))
        #expect(model.status(now: start).explanation(limit: 10, energy: model.energyHold).hasPrefix("Resting on battery"))

        // "Resume" during the rest: it counts anyway, and the rule does not undo that.
        model.resume()
        model.checkEnergy()
        #expect(model.energyHold == nil && !model.showsResume)
        // Plugged in, then on battery again: the rule applies again.
        onBattery = false
        model.checkEnergy()
        onBattery = true
        model.checkEnergy()
        #expect(model.energyHold == .battery)
        onBattery = false
        model.checkEnergy()
        #expect(model.energyHold == nil)
    }

    @Test("Quiet during calls holds the banners only when it is switched on and the microphone is in use")
    func quietDuringCalls() {
        let model = running()
        var inUse = true
        model.microphoneInUse = { inUse }
        #expect(!model.reminders.busy().call, "off unless chosen")
        model.preferences.quietDuringCalls = true
        #expect(model.reminders.busy().call && !model.reminders.mayShowRoutineBanner())
        inUse = false
        #expect(!model.reminders.busy().call && model.reminders.mayShowRoutineBanner())
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

    @Test("Quitting writes the minute in progress when it holds enough to have a rate")
    func minuteSavedOnQuit() {
        let history = HistoryController(store: SampleData.scratchHistory())
        let start = Date(timeIntervalSince1970: 1_800_000_040)
        history.update(current: MinuteRecord(start: start, observedSeconds: 8, blinks: 2))
        history.saveCurrentMinute(now: start)
        #expect(history.minutes.isEmpty, "eight seconds are too few to be a minute's rate")
        history.update(current: MinuteRecord(start: start, observedSeconds: 41, blinks: 9))
        history.saveCurrentMinute(now: start)
        #expect(history.minutes.count == 1 && history.minutes[0].blinks == 9 && history.currentMinute == nil)
        #expect(history.store.load(since: .distantPast).count == 1)
    }

    @Test("A finished blink break says its result: the blinks it counted, and how long they took")
    func blinkBreakResult() {
        let breaks = BlinkBreakController()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        breaks.start(now: start)
        for index in 0..<10 {
            #expect(breaks.seconds == nil)
            breaks.record(.blink(Blink(start: Double(index), end: Double(index) + 0.2)), now: start.addingTimeInterval(Double(index + 1) * 3.8))
        }
        #expect(breaks.exercise?.isDone == true && breaks.seconds == 38)
        #expect(BlinkBreakWords.result(blinks: 10, seconds: 38) == "10 blinks in 38 seconds. No blink reminder for 20 minutes.")
        #expect(!BlinkBreakWords.result(blinks: 10, seconds: nil).contains("full"), "it counts any blink, and does not claim more")
        breaks.stop()
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

    @Test("Reset to Defaults puts every choice back, and keeps what was measured or lived")
    func resetChoices() {
        withStore { store in
            let preferences = Preferences(defaults: store)
            #expect(!preferences.hasChoices, "a new install has nothing to reset")
            let measured = Reference(rate: 12.4, measuredOn: Date(timeIntervalSince1970: 1_800_000_000), minutes: 200)
            let pausedUntil = Date(timeIntervalSince1970: 1_800_003_600)
            // What was measured or lived, and the routines, which share the store.
            preferences.reference = measured
            preferences.welcomed = true
            preferences.pause = .paused(until: pausedUntil)
            preferences.quietUntil = pausedUntil
            store.set(Data([1, 2, 3]), forKey: "routines")
            // Choices, one of each kind.
            preferences.showRateInMenuBar = false
            preferences.blinkBack = false
            preferences.remindersOn = false
            preferences.automaticLimit = false
            preferences.floor = 4
            preferences.ownRateOfferAnswered = true
            preferences.breakPlan = BreakPlan(workMinutes: 25, breakSeconds: 40, longEvery: 4, longMinutes: 7)
            preferences.breakNudgesOn = true
            preferences.breakEndSound = false
            preferences.pauseOnBattery = true
            preferences.quietDuringCalls = true
            preferences.liveViewSound = true
            preferences.cameraID = "desk"
            #expect(preferences.hasChoices)

            preferences.resetChoices()

            // As a new install reads them, now and after a relaunch.
            for read in [preferences, Preferences(defaults: store)] {
                #expect(!read.hasChoices)
                #expect(read.showRateInMenuBar && read.blinkBack && read.remindersOn && read.automaticLimit)
                #expect(read.floor == PublishedRates.startingFloor && !read.ownRateOfferAnswered)
                #expect(read.breakPlan == BreakPlan.Preset.classic.plan && !read.breakNudgesOn && read.breakEndSound)
                #expect(!read.pauseOnBattery && !read.quietDuringCalls && !read.liveViewSound && read.cameraID == nil)
                // Kept.
                #expect(read.reference == measured && read.welcomed)
                #expect(read.pause == .paused(until: pausedUntil) && read.quietUntil == pausedUntil)
            }
            #expect(store.data(forKey: "routines") == Data([1, 2, 3]), "the routines are not choices of Settings")
            #expect(EraseWords.choices.text.contains("Your usual rate") && EraseWords.choices.text.hasSuffix("This cannot be undone."))
        }
    }

    @Test("Quiet outside working hours is off until chosen, is kept, and Reset takes it back")
    func workingHours() {
        withStore { store in
            let preferences = Preferences(defaults: store)
            #expect(!preferences.workingHoursOn && preferences.workingHours == nil, "quiet by default: nothing changes untouched")
            preferences.workingHoursOn = true
            preferences.workStart = TimeOfDay(hour: 8, minute: 30)
            preferences.workDays = [2, 3]
            let read = Preferences(defaults: store)
            #expect(read.workingHours == WorkingHours(start: TimeOfDay(hour: 8, minute: 30), end: TimeOfDay(hour: 18), weekdays: [2, 3]))
            #expect(read.hasChoices)
            read.resetChoices()
            #expect(!read.hasChoices && Preferences(defaults: store).workingHours == nil)
            #expect(Preferences(defaults: store).workStart == WorkingHours.usual.start)
        }
    }

    @Test("Outside the working hours the reminders are quiet, and the panel says why and until when")
    func quietOutsideHours() {
        withStore { store in
            let preferences = Preferences(defaults: store)
            let reminders = ReminderController(preferences: preferences)
            let calendar = Calendar.current
            // Saturday 21 November 2026 at 11:00, on this Mac's clock.
            let saturday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 11)) ?? Date()
            let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9)) ?? Date()
            #expect(reminders.quietReason(now: saturday) == nil && reminders.mayShowRoutineBanner(now: saturday))
            preferences.workingHoursOn = true        // read at the next question, nothing to keep in step
            #expect(reminders.quietReason(now: saturday) == .outsideHours(until: monday))
            #expect(reminders.isQuiet(now: saturday) && !reminders.mayShowRoutineBanner(now: saturday))
            let line = QuietWords.line(.outsideHours(until: monday), now: saturday)
            #expect(line.hasPrefix("Quiet until ") && line.contains("outside your working hours") && line.contains(QuietWords.effect))
            #expect(line.contains(Format.ahead(monday, from: saturday)) && Format.ahead(monday, from: saturday) != Format.time(monday),
                    "two days ahead, the day is named")
            // The Quiet chosen in the panel keeps its own sentence, with the same effect.
            #expect(QuietWords.line(.chosen(until: monday), now: saturday).contains(QuietWords.effect))
            preferences.workingHoursOn = false
            #expect(reminders.quietReason(now: saturday) == nil)
        }
    }

    @Test("The shortcut for a blink break: none until chosen, registered when the app starts it, a refusal said")
    func shortcut() {
        /// Stands for macOS: it refuses one combination, as when another app holds it.
        @MainActor final class StatedKeys: HotKeys {
            var held: ShortcutChoice?
            var press: () -> Void = {}
            var asked = 0
            func register(_ choice: ShortcutChoice, pressed: @escaping () -> Void) -> Bool {
                asked += 1
                guard choice != .controlShiftCommandB else { return false }
                (held, press) = (choice, pressed)
                return true
            }
            func unregister() { (held, press) = (nil, {}) }
        }
        withStore { store in
            let preferences = Preferences(defaults: store)
            #expect(preferences.blinkBreakShortcut == nil && !preferences.hasChoices, "off by default")
            let keys = StatedKeys()
            let controller = ShortcutController(preferences: preferences, keys: keys)
            preferences.blinkBreakShortcut = .controlOptionCommandB
            #expect(keys.asked == 0, "nothing is taken from this Mac before the app starts it")
            var presses = 0
            controller.start { presses += 1 }
            #expect(keys.held == .controlOptionCommandB && controller.refused == nil)
            keys.press()
            #expect(presses == 1)
            // Kept across a relaunch.
            #expect(Preferences(defaults: store).blinkBreakShortcut == .controlOptionCommandB)
            // macOS refuses the next one: nothing is held, and the row says so by name.
            preferences.blinkBreakShortcut = .controlShiftCommandB
            #expect(keys.held == nil && controller.refused == .controlShiftCommandB)
            let said = ShortcutWords.detail(chosen: preferences.blinkBreakShortcut, refused: controller.refused)
            #expect(said.contains("⌃⇧⌘B") && said.contains("Choose another"))
            // Another choice is accepted, and the refusal is forgotten.
            preferences.blinkBreakShortcut = .optionShiftCommandB
            #expect(keys.held == .optionShiftCommandB && controller.refused == nil)
            // Off, and Reset to Defaults, give the key back.
            preferences.blinkBreakShortcut = .controlOptionShiftB
            preferences.resetChoices()
            #expect(keys.held == nil && preferences.blinkBreakShortcut == nil)
            controller.stop()
            preferences.blinkBreakShortcut = .controlOptionCommandB
            #expect(keys.held == nil, "a stopped controller takes nothing")
        }
        // Four different combinations, each with three modifier keys and B.
        #expect(Set(ShortcutChoice.allCases.map(\.modifiers)).count == ShortcutChoice.allCases.count)
        for choice in ShortcutChoice.allCases {
            #expect(choice.modifiers.nonzeroBitCount == 3 && choice.symbols.hasSuffix("B") && choice.symbols.count == 4)
        }
    }

    @Test("Larger text: off until chosen, untouched fonts while off, every style larger while on")
    func largerText() {
        withStore { store in
            let preferences = Preferences(defaults: store)
            #expect(!preferences.largerText && !preferences.hasChoices)
            preferences.largerText = true
            #expect(Preferences(defaults: store).largerText && preferences.hasChoices)
            preferences.resetChoices()
            #expect(!Preferences(defaults: store).largerText)
        }
        // Off: the system's own font, so nothing differs for whoever touches nothing.
        #expect(TextScale.font(.callout, scale: 1) == Font.system(.callout))
        #expect(TextScale.font(.caption, weight: .semibold, scale: 1) == Font.system(.caption).weight(.semibold))
        #expect(TextScale.font(.title, weight: .bold, design: .rounded, scale: 1) == Font.system(.title, design: .rounded).weight(.bold))
        // On: each style at its size times the scale, in whole points, with its own weight.
        #expect(TextScale.font(.callout, scale: TextScale.larger) == Font.system(size: 14, weight: .regular, design: .default))
        #expect(TextScale.font(.headline, scale: TextScale.larger) == Font.system(size: 16, weight: .bold, design: .default))
        #expect(TextScale.font(.caption, weight: .semibold, scale: TextScale.larger) == Font.system(size: 12, weight: .semibold, design: .default))
        // No style gets smaller than the one above it was.
        let styles: [Font.TextStyle] = [.caption2, .caption, .subheadline, .callout, .body, .title3, .title2, .title, .largeTitle]
        let sizes = styles.map(TextScale.points)
        #expect(sizes == sizes.sorted() && sizes.first == 10)
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
        #expect(ordinary.contains("lower the lowest limit"))

        // Under what studies report: the counting is the likely reason, not the person.
        let missed = PublishedRates.limitAboveUsual(reference: Reference(rate: 0.9, measuredOn: day, minutes: 200),
                                                    limit: 4, canLower: false)
        #expect(missed.contains("Live View") && !missed.contains("ordinary"))
        #expect(missed.contains("cannot go lower") && !missed.contains("lower the lowest limit"))
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
        for folder in ["Sources/BlinkMonitor", "Sources/BlinkUI"] {
            let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains(stored) { offenders.append(file.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "a stored Date() in: \(offenders)")
    }

    @Test("No retired word comes back in what a user reads")
    func noRetiredWord() throws {
        // One thing, one name (the audit of 22 November 2026 found six names for two
        // numbers). Names in the code may stay: only text between quotes is read, and
        // comment lines are skipped.
        let retired = ["your reference", "the reference", "Never under", "your floor", "nudge", "on target", "trainer",
                       "analysed)", "is analysed", "blinks per minute", "Blinks per minute", "Snooze", "watched\"",
                       "...\"", "Blink Monitor - ", "Session \\(", " Session\"",
                       // Tier 3 of the same audit.
                       "\"--\"", "Show the Files", "Show Data File", "Go Back to the Model", "forget to.\"", "read as an abstract",
                       "Your own\""]
        var offenders: [String] = []
        for folder in ["Sources/BlinkMonitor", "Sources/BlinkUI"] {
            let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.drop { $0 == " " }
                    guard !trimmed.hasPrefix("//"), let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\"") else { continue }
                    let quoted = line[first...last]
                    for word in retired where quoted.contains(word) {
                        offenders.append("\(file.lastPathComponent):\(number + 1) \(word)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "a retired word in: \(offenders)")
    }

    @Test("A window's main button is made with mainButton(), so that the pictures draw it tinted")
    func mainButtons() throws {
        // `.keyboardShortcut(.defaultAction)` alone is drawn grey in a picture, which is
        // rendered in a window that is never in front (`MainButton.swift`).
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources/BlinkMonitor"), includingPropertiesForKeys: nil)
        for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
            if try String(contentsOf: file, encoding: .utf8).contains(".keyboardShortcut(.defaultAction)") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "a main button made by hand in: \(offenders)")
    }

    @Test("A text style is asked through textStyle(), so that Larger text reaches it; a small control through smallControl()")
    func textStyles() throws {
        // `.font(.callout)` on a view stays 12 points whatever the switch says. Text drawn
        // inside a chart (`context.draw`) keeps its size on purpose, and is let through.
        let style = try NSRegularExpression(pattern: #"\.font\(\.(largeTitle|title|title2|title3|headline|body|callout|subheadline|footnote|caption|caption2)\b"#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources/BlinkMonitor"), includingPropertiesForKeys: nil)
        for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let drawn = line.contains("context.") || (number > 0 && lines[number - 1].contains("let label = Text("))
                let styled = style.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                if (styled && !drawn) || line.contains(".controlSize(.small)") { offenders.append("\(file.lastPathComponent):\(number + 1)") }
            }
        }
        #expect(offenders.isEmpty, "a text style or a small control that Larger text cannot reach: \(offenders)")
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

    @Test("Learning the usual rate says what is left: the time, and the second day")
    func calibrationWords() {
        func line(hours: Double, days: Int) -> String {
            CalibrationWords.line(Baseline.Calibration(watchedSeconds: hours * 3600, days: days), limit: 10)
        }
        // The first day: time is missing, and so is a second day.
        #expect(line(hours: 1 + 20.0 / 60, days: 1)
                == "Learning your usual rate: 1 h 20 min of 3 h, over 2 days. It can finish tomorrow. Until then the limit is 10 a minute.")
        // The first day, a long one: only the second day is missing. It no longer stops at "50%".
        #expect(line(hours: 5, days: 1).contains("all on one day") && line(hours: 5, days: 1).contains("finishes tomorrow"))
        // The second day: only time is missing.
        #expect(line(hours: 2.5, days: 2).contains("2 h 30 min of 3 h. 30 min to go."))
    }

    @Test("A failure to start is a sentence for a person: no error text, no command")
    func startFailureWords() {
        for failure in [StartFailure.model(trainedHere: true), .model(trainedHere: false), .noCamera, .camera, .cameraLeftOff] {
            let sentence = failure.sentence
            #expect(!sentence.contains("make ") && !sentence.contains("--") && !sentence.contains("Error"))
            #expect(sentence.contains("counted"))
        }
        #expect(StartFailure.model(trainedHere: true).offersSetup && !StartFailure.camera.offersSetup)
        // With no rate to show, the panel writes the state where the number would be.
        #expect(MonitorStatus.paused(until: nil).headline == "Paused")
        #expect(MonitorStatus.noFace.headline == "No face")
        #expect(MonitorStatus.watching(rate: nil).headline == "Starting")
        #expect(MonitorStatus.watching(rate: 13).headline == nil)
        #expect(MonitorStatus.watching(rate: 13).explanation(limit: 10) == "Your rate over the last minute. Your limit is 10.")
    }

    @Test("Deleting the recordings and the model also removes the captures saved from Live View")
    @MainActor func deleteIncludesCaptures() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("blink-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessions = base.appendingPathComponent("sessions", isDirectory: true)
        let captures = base.appendingPathComponent("captures", isDirectory: true)
        for folder in [sessions, captures.appendingPathComponent("20270101-100000-free", isDirectory: true)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let model = MonitorModel(preferences: .temporary(), history: HistoryController(store: SampleData.scratchHistory()),
                                 modelStore: ModelStore(base: base))
        try await model.deleteModelAndRecordings(sessions: sessions, own: true, captures: captures)
        #expect(!FileManager.default.fileExists(atPath: sessions.path))
        #expect(!FileManager.default.fileExists(atPath: captures.path))
        // The record buttons belong to whoever started the app with a folder for captures.
        #expect(!Options.developerTools)
    }

    @Test("A blink break is left out of the count: no watched time and no blink, but its blinks are still reported")
    func exerciseLeftOut() throws {
        var eyes = DemoEyes()
        let pipeline = MonitorPipeline()
        pipeline.setLiveView(true)                 // report every frame
        var updates: [MonitorUpdate] = []
        pipeline.onUpdate = { updates.append($0) }
        func run(from start: Double, seconds: Double) {
            for frame in 0..<Int(seconds * 30) {
                let time = start + Double(frame) / 30
                pipeline.process(eyes.reading(at: time), time: time)
            }
        }
        run(from: 1000, seconds: 60)
        let before = try #require(updates.last?.live.counters)
        #expect(before.observedSeconds > 55 && before.totalBlinks > 5)

        eyes.pace = .exercise                      // slow, full blinks
        pipeline.setExercise(true)
        updates = []
        run(from: 1060, seconds: 40)
        let during = try #require(updates.last?.live.counters)
        #expect(during.observedSeconds == before.observedSeconds && during.totalBlinks == before.totalBlinks)
        #expect(updates.compactMap(\.event).count >= 5)          // the exercise still hears them
        #expect(updates.compactMap(\.completedMinute).allSatisfy { $0.observedSeconds <= 60 })

        eyes.pace = .usual
        pipeline.setExercise(false)
        run(from: 1100, seconds: 10)
        #expect(try #require(updates.last?.live.counters).observedSeconds > before.observedSeconds + 9)
    }
}

@Suite("The panel's sentence")
struct PanelSentenceTests {

    @Test("A pause held by a routine's timer names the routine; an ordinary pause does not")
    func timerPause() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = MonitorStatus.paused(until: until).explanation(limit: 10, timer: "Heated eye mask")
        #expect(timed.hasPrefix("Paused for Heated eye mask, until ") && timed.contains("by itself"))
        let plain = MonitorStatus.paused(until: until).explanation(limit: 10)
        #expect(plain.hasPrefix("The camera is off until ") && plain.contains("Routines still remind you"))
        #expect(MonitorStatus.watching(rate: 12).explanation(limit: 10, timer: "Heated eye mask").contains("Your limit is 10"))
    }

    @Test("The low rate is one sentence, in the panel, on the banner and in the tooltip")
    func lowRateSaidOnce() {
        let low = MonitorStatus.low(rate: 6, recent: 7)
        #expect(LowRateWords.sentence(limit: 10) == "Under your limit of 10 over the last 3 minutes.")
        // The large number above is the last minute: the sentence gives no second rate to confuse it with.
        #expect(low.explanation(limit: 10) == "Under your limit of 10 over the last 3 minutes. Try a blink break: ten slow, full blinks.")
        #expect(low.tooltip(limit: 10) == "Low: under your limit of 10 over the last 3 minutes")
    }

    @Test("A camera that sends nothing: the lid is named only where there is one")
    func noLidWithoutALid() {
        #expect(MonitorStatus.cameraSilent.explanation(limit: 10, camera: .lid).contains("the lid closed"))
        for place in [CameraPlace.screen, .separate] {
            let said = MonitorStatus.cameraSilent.explanation(limit: 10, camera: place) + CameraNote.silentAdvice(place) + CameraNote.faceIt(place)
            #expect(!said.contains("lid"))
        }
        #expect(!CameraNote.findOne(macHasLid: false).contains("lid"))
        #expect(!CameraWords.detail(inUse: nil, macHasLid: false).contains("lid"))
        #expect(AppWords.tagline.hasSuffix("when you forget to blink."))
    }
}

@MainActor
@Suite("Settings")
struct SettingsWordsTests {

    @Test("Seven tabs, the last one About; every erasing question says it cannot be undone")
    func tabsAndQuestions() {
        #expect(SettingsState.Tab.allCases.map(\.rawValue) == ["General", "Blink Rate", "Breaks", "Routines", "Model", "Privacy", "About"])
        let questions = [EraseWords.history(startingLimit: 10), EraseWords.routineLog, EraseWords.captures(2),
                         EraseWords.startAgain, EraseWords.everything]
        for question in questions {
            #expect(question.text.contains("cannot be undone"), "\(question.title)")
            #expect(question.button != "OK" && question.button != "Cancel")
        }
        #expect(EraseWords.history(startingLimit: 10).text.contains("goes back to 10"))
        #expect(EraseWords.captures(1).text.hasPrefix("1 capture of"))
    }

    @Test("Erasing the routine log empties it and keeps the routines")
    func routineLogErased() throws {
        let routines = SampleData.demoModel().routines
        // The demo's log is a file of its own in the temporary folder: never the user's.
        try #require(routines.store.file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let before = routines.routines
        routines.eraseRecord()
        #expect(routines.events.isEmpty && routines.routines == before)
    }
}

@Suite("The menu-bar item")
struct MenuBarMarksTests {

    @Test("The rate keeps a slot two digits wide, so the item does not move when it crosses ten")
    func fixedSlot() {
        #expect(MonitorStatus.slot("9") == "\u{2007}9")
        #expect(MonitorStatus.slot("10") == "10")
        #expect(MonitorStatus.slot(RateReadout.none).count == 2)
        #expect(MonitorStatus.watching(rate: 9).menuBarText.count == MonitorStatus.low(rate: 12, recent: 9).menuBarText.count)
        // A state that shows no rate takes no room for one.
        #expect(MonitorStatus.paused(until: nil).menuBarText.isEmpty && MonitorStatus.needsSetup.menuBarText == "!")
    }

    @Test("Each thing going on has its symbol, and the tooltip says each in words")
    func marks() {
        #expect(MenuBarMarks().symbols.isEmpty)
        #expect(MenuBarMarks().tooltip(after: "Blink Monitor is paused") == "Blink Monitor is paused")

        let drops = MenuBarMarks.Routine(title: "Eye drops", symbol: "drop")
        var marks = MenuBarMarks(waiting: [drops])
        #expect(marks.symbols == ["drop"], "one routine shows its own symbol")
        #expect(marks.tooltip(after: "Low") == "Low. Waiting: Eye drops")

        marks.waiting.append(.init(title: "Heated eye mask", symbol: "eye"))
        marks.onBreak = true
        #expect(marks.symbols == ["eyes", "circle.fill"], "several routines share one dot")
        #expect(marks.sentences == ["Look-away break", "Waiting: Eye drops, Heated eye mask"])

        let quiet = MenuBarMarks(quietUntil: Date(timeIntervalSince1970: 1_800_000_000), timerUntil: Date(timeIntervalSince1970: 1_800_000_600))
        #expect(quiet.symbols == ["timer", "bell.slash"])
        #expect(quiet.sentences.count == 2 && quiet.sentences[0].hasPrefix("Timer until ") && quiet.sentences[1].hasPrefix("Quiet until "))
    }
}

/// The History window's earlier weeks, read from a file of the test's own.
@MainActor
@Suite("History beyond seven days")
struct HistoryWeeksControllerTests {

    @Test("The earlier weeks are read when the window opens, joined to what is counted since, and let go when it closes")
    func earlierWeeks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(file: folder.appendingPathComponent("history.csv"))
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 16)) ?? Date()
        func minute(daysBack: Int, _ offset: Int, blinks: Int) -> MinuteRecord {
            let day = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now)) ?? now
            return MinuteRecord(start: day.addingTimeInterval(10 * 3600 + Double(offset) * 60), observedSeconds: 60, blinks: blinks)
        }
        // On file: half a year ago (not shown), three weeks ago, and yesterday.
        var onFile = [minute(daysBack: 180, 0, blinks: 5)]
        onFile += (0..<20).map { minute(daysBack: 22, $0, blinks: 8) }
        onFile += (0..<20).map { minute(daysBack: 1, $0, blinks: 14) }
        for record in onFile { store.append(record) }
        let history = HistoryController(store: store)
        history.load(now: now)
        #expect(history.minutes.count == 20 && history.earlier == nil, "the app itself keeps the last days only")
        #expect(history.records(on: minute(daysBack: 22, 0, blinks: 0).start).isEmpty)

        history.loadEarlier(now: now)
        #expect(history.earlier?.count == 40, "twelve weeks back, no further")
        #expect(history.allRecords().count == 40, "yesterday is not counted twice")
        // A minute counted while the window is open is in, once.
        history.minuteEnded(MinuteRecord(start: now.addingTimeInterval(-60), observedSeconds: 60, blinks: 13), now: now)
        #expect(history.allRecords().count == 41)
        // Three weeks ago is the fourth week back, at 8 blinks a minute.
        let week = HistoryWeeks.week(3, now: now, calendar: calendar)
        let days = history.days(of: week, threshold: 10)
        #expect(days.count == 7 && days.compactMap(\.summary.ratePerMinute) == [8])
        #expect(history.records(on: minute(daysBack: 22, 0, blinks: 0).start).count == 20)
        #expect(HistoryWords.title(of: week) != "Last 7 days" && HistoryWords.title(of: HistoryWeeks.week(0, now: now, calendar: calendar)) == "Last 7 days")

        history.forgetEarlier()
        #expect(history.earlier == nil && history.allRecords().count == 21)
        // Erasing the history with the window open empties the weeks too.
        history.loadEarlier(now: now)
        history.erase()
        #expect(history.allRecords().isEmpty && history.earlier?.isEmpty == true)
    }
}

/// The break log as the app keeps it, on a file of the test's own.
@MainActor
@Suite("The break log")
struct CareControllerTests {

    @Test("What the app did is written down, shown in History's words, and erased on request")
    func log() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-care-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let care = CareController(store: CareStore(file: folder.appendingPathComponent("breaks.csv")))
        #expect(care.events.isEmpty && KeptWords.lines(Kept()).isEmpty, "nothing kept, nothing said")
        // (The file keeps whole seconds.)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        care.record(CareEvent(BreakOutcome(kind: .short, ending: .away), at: now))
        care.record(.blinkReminder, now: now)
        care.record(.blinkBreak, now: now)
        // A relaunch reads them back.
        #expect(CareController(store: care.store).events == care.events && care.events.count == 3)
        let kept = Kept(week: HistoryWeeks.week(0, now: now, calendar: .current), care: care.events,
                        routines: [RoutineEvent(at: now, routine: "eye-drops", slot: "a", action: .done)])
        #expect(KeptWords.lines(kept).map(\.text) == ["1 look-away break taken", "1 blink break finished, 1 blink reminder shown",
                                                      "Routines marked done once"])
        care.erase()
        #expect(care.events.isEmpty && !FileManager.default.fileExists(atPath: care.store.file.path))
    }

    @Test("The model writes a finished blink break to its log, and a made-up model never touches the real file")
    func hooks() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-care-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let care = CareController(store: CareStore(file: folder.appendingPathComponent("breaks.csv")))
        let model = MonitorModel(preferences: .temporary(), initial: MonitorModel.InitialState(), care: care)
        model.blinkBreak.onDone()
        model.reminders.onBlinkReminder(Date())
        model.reminders.breaks.onOutcome(BreakOutcome(kind: .short, ending: .skipped), Date())
        #expect(care.events.map(\.kind) == [.blinkBreak, .blinkReminder, .skipped])
        // The demo and the screenshots: a log in the temporary folder.
        let sample = MonitorModel(preferences: .temporary(), initial: MonitorModel.InitialState())
        #expect(sample.care.store.file != CareStore.defaultFile)
        #expect(sample.care.store.file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test("The comparison is two numbers of the person's own, and says that they explain nothing")
    func findingWords() {
        let said = KeptWords.finding(KeptFinding(breaks: 6, daysWith: 9, rateWith: 14.1, daysWithout: 7, rateWithout: 11.3))
        #expect(said.contains("On the 9 days with 6 or more look-away breaks") && said.contains("On the 7 other days"))
        #expect(said.hasSuffix("they do not say why."))
        // No cause, no promise, no advice.
        for word in ["because", "help", "should", "improve", "better", "thanks to", "cause", "try"] {
            #expect(!said.lowercased().contains(word), "\(word)")
        }
    }
}

/// The optional summary banner: its words, and when the app shows it.
@MainActor
@Suite("The summary of the day, in the app")
struct SummaryTests {

    private func store() -> UserDefaults {
        let name = "local.blinkmonitor.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test("The sentence states numbers, says when there are too few, and gives no advice")
    func words() {
        let counted = DayDigest(day: .counted(seconds: 5 * 3600 + 600, rate: 13.2, aboveLimit: 81), breaksTaken: 6,
                                lastWeek: DayDigest.Week(seconds: 30 * 3600, rate: 11.8))
        let said = SummaryWords.body(counted, limit: 10) ?? ""
        #expect(said.hasPrefix("5 h 10 min at the screen, \(Format.rate(13.2)) blinks a minute, 81% of the time above your limit of 10."))
        #expect(said.contains("6 look-away breaks taken.") && said.hasSuffix("The seven days before: 30 h at the screen, \(Format.rate(11.8)) blinks a minute."))
        #expect(SummaryWords.body(DayDigest(day: .tooLittle(seconds: 20 * 60)), limit: 10) == "20 min at the screen: too little to give a rate.")
        #expect(SummaryWords.body(DayDigest(day: .notAtScreen, breaksTaken: 2), limit: 10) == nil, "a day off gets no banner")
        #expect(SummaryWords.body(DayDigest(day: .counted(seconds: 3600, rate: 9, aboveLimit: nil), breaksTaken: 1), limit: 10)
                == "1 h at the screen, \(Format.rate(9)) blinks a minute. 1 look-away break taken.")
        for word in ["should", "try", "good", "bad", "well done", "too low", "healthy"] {
            #expect(!said.lowercased().contains(word), "\(word)")
        }
        // An hour after the working hours would never show: Settings says so.
        #expect(SummaryWords.isHeldBack(hour: 19, by: .usual) && !SummaryWords.isHeldBack(hour: 17, by: .usual))
        #expect(!SummaryWords.isHeldBack(hour: 19, by: nil))
        let night = WorkingHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 6), weekdays: [2])
        #expect(!SummaryWords.isHeldBack(hour: 23, by: night) && !SummaryWords.isHeldBack(hour: 5, by: night) && SummaryWords.isHeldBack(hour: 12, by: night))
    }

    @Test("Off by default; on, it is shown once from its hour on, waits for the gate, and is silent about an empty day")
    func shownOnce() {
        let defaults = store()
        let preferences = Preferences(defaults: defaults)
        #expect(!preferences.summaryOn && preferences.summaryHour == 17 && !preferences.hasChoices)
        let reminders = ReminderController(preferences: preferences)
        var shown: [String] = []
        reminders.onSummary = { shown.append($0) }
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date()
        }
        let minutes = (0..<120).map { MinuteRecord(start: at(9).addingTimeInterval(Double($0) * 60), observedSeconds: 60, blinks: 12) }

        reminders.summaryIfDue(minutes: minutes, now: at(17, 1))
        #expect(shown.isEmpty, "off: nothing changes for whoever touches nothing")
        preferences.summaryOn = true
        reminders.summaryIfDue(minutes: minutes, now: at(16, 59))
        #expect(shown.isEmpty, "not before its hour")
        // Quiet holds it back; it comes when Quiet is over, the same day.
        reminders.setQuiet(until: at(17, 30))
        reminders.summaryIfDue(minutes: minutes, now: at(17, 1))
        #expect(shown.isEmpty)
        // So does something the person is in the middle of.
        reminders.busy = { BannerGate.Busy(blinkBreak: true) }
        reminders.summaryIfDue(minutes: minutes, now: at(17, 31))
        #expect(shown.isEmpty)
        reminders.busy = { .free }
        reminders.summaryIfDue(minutes: minutes, now: at(17, 32))
        #expect(shown.count == 1 && shown[0].hasPrefix("2 h at the screen"))
        #expect(!reminders.mayShowRoutineBanner(now: at(17, 33)), "it takes its place in the two minutes between banners")
        reminders.summaryIfDue(minutes: minutes, now: at(18))
        #expect(shown.count == 1, "once a day")
        #expect(Preferences(defaults: defaults).summaryShownDay == "2026-11-20", "and not again after a relaunch")
        // The next day, nothing counted: no banner, and it is not asked for again that day.
        reminders.summaryIfDue(minutes: minutes, now: at(17, 5, day: 21))
        #expect(shown.count == 1 && preferences.summaryShownDay == "2026-11-21")
        // Reset to Defaults switches it off.
        preferences.resetChoices()
        #expect(!preferences.summaryOn && !preferences.hasChoices)
    }
}

/// The optional evening question, on notes and settings of the test's own.
@MainActor
@Suite("How the eyes feel, in the app")
struct EyeNoteControllerTests {

    private func parts() -> (Preferences, EyeNoteController, URL) {
        let name = "local.blinkmonitor.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-notes-\(UUID().uuidString)", isDirectory: true)
        let preferences = Preferences(defaults: store)
        return (preferences, EyeNoteController(preferences: preferences, store: EyeNoteStore(file: folder.appendingPathComponent("eye-notes.csv"))), folder)
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date()
    }

    @Test("Off by default; on, it asks once from its hour on, waits for the gate, and does not ask a day already answered")
    func asks() {
        let (preferences, notes, folder) = parts()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!preferences.eyeNoteOn && !preferences.hasChoices)
        var asked = 0, allowed = true, shownAt: [Date] = []
        notes.onAsked = { asked += 1 }
        notes.mayShowBanner = { _ in allowed }
        notes.bannerShown = { shownAt.append($0) }

        notes.askIfDue(now: at(18))
        #expect(asked == 0, "off: no question")
        preferences.eyeNoteOn = true
        notes.askIfDue(now: at(16, 59))
        #expect(asked == 0, "not before its hour")
        allowed = false                              // Quiet, a break, the working hours: the gate says no
        notes.askIfDue(now: at(17, 1))
        #expect(asked == 0 && preferences.eyeNoteAskedDay == nil, "held back is not asked: it comes when the gate opens")
        allowed = true
        notes.askIfDue(now: at(17, 5))
        #expect(asked == 1 && shownAt == [at(17, 5)], "it takes its place between the other banners")
        notes.askIfDue(now: at(17, 30))
        #expect(asked == 1, "once a day")

        // The next day it was answered in History before the hour: nothing is asked.
        notes.note(.aLittleTired, now: at(15, day: 21))
        notes.askIfDue(now: at(17, 5, day: 21))
        #expect(asked == 1 && notes.today(now: at(18, day: 21)) == .aLittleTired)
        // An answer changed the same day replaces the first; yesterday has none.
        notes.note(.fine, now: at(19, day: 21))
        #expect(notes.today(now: at(20, day: 21)) == .fine && notes.today(now: at(20)) == nil)
        // A relaunch reads the notes back; Erase removes them and the file.
        #expect(EyeNoteController(preferences: preferences, store: notes.store).notes.count == 2)
        notes.erase()
        #expect(notes.notes.isEmpty && !FileManager.default.fileExists(atPath: notes.store.file.path))
        preferences.resetChoices()
        #expect(!preferences.eyeNoteOn)
    }

    @Test("The question goes through the one gate, and a made-up model never touches the real file")
    func gate() {
        let model = MonitorModel(preferences: .temporary(), initial: MonitorModel.InitialState())
        #expect(model.eyeNotes.store.file != EyeNoteStore.defaultFile)
        #expect(model.eyeNotes.store.file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        model.preferences.eyeNoteOn = true
        var asked = 0
        model.eyeNotes.onAsked = { asked += 1 }
        let now = at(17, 5)
        model.reminders.setQuiet(until: now.addingTimeInterval(600))
        model.eyeNotes.askIfDue(now: now)
        #expect(asked == 0, "Quiet holds it")
        model.reminders.setQuiet(until: nil)
        model.eyeNotes.askIfDue(now: now.addingTimeInterval(660))
        #expect(asked == 1)
        #expect(!model.reminders.mayShowRoutineBanner(now: now.addingTimeInterval(700)), "two minutes before any other banner")
    }

    @Test("Four plain words, and nothing that interprets, diagnoses or advises")
    func words() {
        #expect(EyeFeeling.allCases.map(EyeNoteWords.name) == ["Fine", "A little tired", "Tired", "Very tired"])
        let everything = [EyeNoteWords.question, EyeNoteWords.bannerBody, EyeNoteWords.rowTitle, EyeNoteWords.row, EyeNoteWords.detail,
                          EyeNoteWords.hourDetail, EyeNoteWords.fileDetail, EraseWords.eyeNotes.text].joined(separator: " ").lowercased()
        for word in ["dry eye", "symptom", "diagnos", "treat", "doctor", "should", "because", "improv", "better", "worse", "help", "strain", "pain"] {
            #expect(!everything.contains(word), "\(word)")
        }
        #expect(EyeNoteWords.detail.contains("does nothing else with it") && EraseWords.eyeNotes.text.hasSuffix("This cannot be undone."))
    }
}
