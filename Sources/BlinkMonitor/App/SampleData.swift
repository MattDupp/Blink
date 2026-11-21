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
        /// A look-away break is running, on a day with a few behind it.
        case lookingAway
        /// A long break, two minutes into it, with the person away from the screen.
        case longBreak
        /// In the middle of a blink break, `count` blinks in.
        case blinkBreak(count: Int)
        /// A minute after the very first launch: nothing recorded yet.
        case firstMinute
        /// The camera has stopped sending pictures (the lid is closed).
        case noPicture
        /// The demo: `watching`, on made-up eyes.
        case demo
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
        // Breaks at the demo's pace: one after a minute, and a long one after two of them.
        preferences.breakNudgesOn = true
        preferences.breakPlan = BreakPlan(workMinutes: 1, breakSeconds: 20, longEvery: 2, longMinutes: 1)
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
                                                cameraNote: "The camera picture is left out of screenshots.")
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
            isDemo = true
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
        case .longBreak:
            initial.live = live.withCameraOff      // away from the screen: nobody in view
            fallthrough
        case .lookingAway:
            preferences.reference = Reference(rate: usual, measuredOn: aWhileAgo, minutes: 214)
            preferences.breakNudgesOn = true
            preferences.breakPlan = BreakPlan(workMinutes: 25, breakSeconds: 40, longEvery: 3, longMinutes: 5)
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
        let model = MonitorModel(preferences: preferences,
                                 history: HistoryController(store: scratchHistory(), minutes: minutes, current: current),
                                 initial: initial, demo: isDemo)
        var tally = BreakTally(day: Calendar.current.startOfDay(for: now))
        for ending in [BreakOutcome.Ending.onTrust, .away, .onTrust, .skipped, .away, .onTrust] {
            tally.record(BreakOutcome(kind: .short, ending: ending), dayStart: tally.day)
        }
        if case .lookingAway = scene {
            model.reminders.breaks.show(current: .init(kind: .short, seconds: 40), tally: tally)
        }
        if case .longBreak = scene {
            tally.record(BreakOutcome(kind: .long, ending: .away), dayStart: tally.day)
            model.reminders.breaks.show(current: .init(kind: .long, seconds: 300, awaySeconds: 130), tally: tally)
        }
        return model
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
