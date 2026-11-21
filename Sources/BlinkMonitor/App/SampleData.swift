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
        let model = MonitorModel(preferences: preferences,
                                 history: HistoryController(store: scratchHistory(), minutes: minutes), demo: true)
        demoRoutine(in: model, now: now)
        return model
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
        return MonitorModel(preferences: preferences,
                            history: HistoryController(store: scratchHistory(), minutes: minutes, current: current),
                            initial: initial, demo: isDemo)
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

    // MARK: Routines

    /// What the screenshots show of a routine's day.
    enum RoutineScene {
        /// Two times done, one to come.
        case kept
        /// One done, one left, one waiting now.
        case waiting
        /// The waiting one was put off.
        case putOff
    }

    /// Switches the built-in routine on in `model` and gives it a made-up day. The model
    /// is a made-up one: its record is a scratch file (see `RoutineController.scratch`).
    static func routines(in model: MonitorModel, now: Date, scene: RoutineScene, calendar: Calendar = .current) {
        let routines = model.routines
        let id = Routine.eyeDrops.id
        let morning = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: morning) ?? now
        }
        func slot(_ hour: Int, _ minute: Int) -> String {
            let day = calendar.dateComponents([.year, .month, .day], from: morning)
            return String(format: "%04d-%02d-%02dT%02d:%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0, hour, minute)
        }
        routines.setOn(id, true, now: morning)
        routines.record(RoutineEvent(at: at(8, 4), routine: id, slot: slot(8, 0), action: .done))
        switch scene {
        case .kept:
            routines.record(RoutineEvent(at: at(13, 20), routine: id, slot: slot(13, 0), action: .done))
        case .waiting, .putOff:
            routines.setTimes(id, [TimeOfDay(hour: 8), TimeOfDay(hour: 12, minute: 30), TimeOfDay(hour: 16, minute: 30)])
            routines.record(RoutineEvent(at: at(16, 30), routine: id, slot: slot(16, 30), action: .shown))
            if case .putOff = scene {
                routines.record(RoutineEvent(at: at(16, 35), routine: id, slot: slot(16, 30), action: .later,
                                             until: at(16, 50)))
            }
        }
    }

    /// The demo's routine: one time done three hours ago, one that falls due two minutes
    /// after the demo opens (so that the reminder is seen), one in four hours. Times that
    /// would fall on another day are left out.
    static func demoRoutine(in model: MonitorModel, now: Date, calendar: Calendar = .current) {
        let id = Routine.eyeDrops.id
        let moments = [-3 * 3600.0, 120, 4 * 3600].map { now.addingTimeInterval($0) }
            .filter { calendar.isDate($0, inSameDayAs: now) }
        let times = moments.map { TimeOfDay(hour: calendar.component(.hour, from: $0), minute: calendar.component(.minute, from: $0)) }
        guard !times.isEmpty else { return }
        model.routines.setTimes(id, times)
        model.routines.setOn(id, true, now: calendar.startOfDay(for: now))
        let day = RoutineDay(routine: model.routines.routines.first { $0.id == id } ?? .eyeDrops, record: [], now: now,
                             calendar: calendar)
        if let first = day.slots.first, first.due < now, moments[0] < now {
            model.routines.record(RoutineEvent(at: first.due.addingTimeInterval(240), routine: id, slot: first.key, action: .done))
        }
    }
}
