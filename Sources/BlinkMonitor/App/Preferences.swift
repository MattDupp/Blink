import SwiftUI
import BlinkCore

/// Every choice the app remembers between launches, in one place.
///
/// They are stored by macOS's UserDefaults (a small per-app file). The first version kept
/// them in two controllers and in the panel; now the Settings window edits this one object
/// and everything else reads it. A key is spelled once, and a screenshot can be given a
/// store of its own instead of the user's real settings (`temporary`).
@MainActor
final class Preferences: ObservableObject {

    private enum Key {
        static let showRate = "showRateInMenuBar"
        static let orangeWhenLow = "orangeRateWhenLow"
        static let liveViewSound = "liveViewSound"
        static let cameraID = "cameraID"
        static let pauseOnBattery = "pauseOnBattery"
        static let pauseInLowPower = "pauseInLowPowerMode"
        static let effort = "effort"
        static let quietDuringCalls = "quietDuringCalls"
        static let blinkBreakShortcut = "blinkBreakShortcut"
        static let largerText = "largerText"
        static let summaryOn = "summaryOn"
        static let summaryHour = "summaryHour"
        static let summaryShownDay = "summaryShownDay"
        static let eyeNoteOn = "eyeNoteOn"
        static let eyeNoteHour = "eyeNoteHour"
        static let eyeNoteAskedDay = "eyeNoteAskedDay"
        static let workingHoursOn = "workingHoursOn"
        static let workStart = "workingHoursStart"
        static let workEnd = "workingHoursEnd"
        static let workDays = "workingHoursDays"
        static let blinkBack = "blinkBack"
        static let remindersOn = "remindersOn"
        static let automaticLimit = "automaticLimit"
        static let floor = "threshold"            // its name in the first version
        static let reference = "reference"
        static let breakNudgesOn = "breakNudgesOn"
        static let breakMinutes = "breakMinutes"
        static let breakSeconds = "breakSeconds"
        static let longBreakOn = "longBreakOn"
        static let longBreakEvery = "longBreakEvery"
        static let longBreakMinutes = "longBreakMinutes"
        static let breakTally = "breakTally"
        static let breakStartSound = "breakStartSound"
        static let breakEndSound = "breakEndSound"
        static let welcomed = "welcomed"
        static let ownRateOfferAnswered = "ownRateOfferAnswered"
        static let quietUntil = "quietUntil"
        static let paused = "paused"
        static let pausedUntil = "pausedUntil"
    }

    /// Also read by `RoutineController`, which keeps the routines in the same store.
    let defaults: UserDefaults

    // MARK: General

    /// The menu bar shows the rate next to the eye (off: the eye alone).
    @Published var showRateInMenuBar: Bool = Standard.showRateInMenuBar { didSet { defaults.set(showRateInMenuBar, forKey: Key.showRate) } }
    /// A short sound at every counted blink while Live View is open. Off unless chosen,
    /// and kept: it was on at every opening, and the Mac popped at each blink.
    @Published var liveViewSound: Bool = Standard.liveViewSound { didSet { defaults.set(liveViewSound, forKey: Key.liveViewSound) } }
    /// Counting rests while the Mac runs on its battery, and while Low Power Mode is on
    /// (`EnergyPause`). Both off unless chosen.
    @Published var pauseOnBattery: Bool = Standard.pauseOnBattery { didSet { defaults.set(pauseOnBattery, forKey: Key.pauseOnBattery) } }
    @Published var pauseInLowPower: Bool = Standard.pauseInLowPower { didSet { defaults.set(pauseInLowPower, forKey: Key.pauseInLowPower) } }
    /// How often the eyes are looked for while counting runs (`Effort`). Standard unless
    /// chosen: what the app did before the choice existed.
    @Published var effort: Effort = Standard.effort { didSet { defaults.set(effort.rawValue, forKey: Key.effort) } }
    /// No banner and no sound while the microphone is in use, which is most likely a call.
    @Published var quietDuringCalls: Bool = Standard.quietDuringCalls { didSet { defaults.set(quietDuringCalls, forKey: Key.quietDuringCalls) } }
    /// "Quiet outside working hours": off unless chosen. The two times are minutes since
    /// midnight, the days are 1 = Sunday ... 7 = Saturday (`WorkingHours`).
    @Published var workingHoursOn: Bool = Standard.workingHoursOn { didSet { defaults.set(workingHoursOn, forKey: Key.workingHoursOn) } }
    @Published var workStart: TimeOfDay = Standard.workStart { didSet { defaults.set(workStart.hour * 60 + workStart.minute, forKey: Key.workStart) } }
    @Published var workEnd: TimeOfDay = Standard.workEnd { didSet { defaults.set(workEnd.hour * 60 + workEnd.minute, forKey: Key.workEnd) } }
    @Published var workDays: Set<Int> = Standard.workDays { didSet { defaults.set(workDays.sorted(), forKey: Key.workDays) } }
    /// The hours as the gate reads them; nil while the switch is off.
    var workingHours: WorkingHours? {
        workingHoursOn ? WorkingHours(start: workStart, end: workEnd, weekdays: workDays) : nil
    }
    /// Every window draws its words about 20% larger (`TextScale`, in BlinkUI).
    @Published var largerText: Bool = Standard.largerText { didSet { defaults.set(largerText, forKey: Key.largerText) } }
    /// The key combination that starts a blink break from any app. Nil: none, which is
    /// how it starts (`ShortcutController`).
    @Published var blinkBreakShortcut: ShortcutChoice? = Standard.blinkBreakShortcut { didSet { defaults.set(blinkBreakShortcut?.rawValue, forKey: Key.blinkBreakShortcut) } }
    /// The camera the user chose, as macOS knows it. Nil: Automatic (`CameraChoice`).
    @Published var cameraID: String? = Standard.cameraID { didSet { defaults.set(cameraID, forKey: Key.cameraID) } }
    /// The rate in the menu bar is written in orange while it is low. The badge on the
    /// eye alone was nearly invisible (audit of 22 November 2026, item 2.17).
    @Published var orangeRateWhenLow: Bool = Standard.orangeRateWhenLow { didSet { defaults.set(orangeRateWhenLow, forKey: Key.orangeWhenLow) } }

    /// The eye in the menu bar closes for a moment each time you blink.
    @Published var blinkBack: Bool = Standard.blinkBack { didSet { defaults.set(blinkBack, forKey: Key.blinkBack) } }

    // MARK: Reminders

    @Published var remindersOn: Bool = Standard.remindersOn { didSet { defaults.set(remindersOn, forKey: Key.remindersOn) } }

    /// The limit follows your own reference (see `Baseline`); off: the limit is `floor`.
    @Published var automaticLimit: Bool = Standard.automaticLimit { didSet { defaults.set(automaticLimit, forKey: Key.automaticLimit) } }

    /// The limit you set by hand, in blinks a minute. With an automatic limit it is the
    /// floor: the limit never goes under it. Where it starts is `PublishedRates.startingFloor`:
    /// a starting point for you to adjust, not a medical limit.
    @Published var floor: Int = Standard.floor { didSet { defaults.set(floor, forKey: Key.floor) } }

    /// The floors the Settings window offers, in blinks a minute.
    ///
    /// Down to 1. The first version stopped at 4, but some healthy people make 0 to 2
    /// complete blinks a minute at a screen (one of the three patterns Freudenthaler 2003
    /// describes, see `PublishedRates`): with a floor of 4 their limit could never come
    /// down to their own usual rate, and the app said "Low" to them all day. Not 0: a
    /// limit of 0 can never be gone under, which is reminders switched off, and that has
    /// its own switch.
    static let floorChoices = 1...20

    /// Your usual rate, measured once and kept (nil until calibration is complete).
    @Published var reference: Reference? {
        didSet {
            let stored: [String: Any]? = reference.map {
                ["rate": $0.rate, "measuredOn": $0.measuredOn, "minutes": $0.minutes]
            }
            defaults.set(stored, forKey: Key.reference)
        }
    }

    /// Under this many blinks a minute is "too little": the one number the app compares with.
    var limit: Int {
        Baseline.limit(reference: reference, automatic: automaticLimit, floor: floor)
    }

    /// A banner once a day, at `summaryHour`, with the day's numbers (`DayDigest`). Off
    /// unless chosen.
    @Published var summaryOn: Bool = Standard.summaryOn { didSet { defaults.set(summaryOn, forKey: Key.summaryOn) } }
    @Published var summaryHour: Int = Standard.summaryHour { didSet { defaults.set(summaryHour, forKey: Key.summaryHour) } }
    /// The day the summary was last shown on (`SummarySchedule.key`): once a day.
    var summaryShownDay: String? {
        get { defaults.string(forKey: Key.summaryShownDay) }
        set { defaults.set(newValue, forKey: Key.summaryShownDay) }
    }

    /// The evening question, "How do your eyes feel?" (`EyeNoteController`). Off unless chosen.
    @Published var eyeNoteOn: Bool = Standard.eyeNoteOn { didSet { defaults.set(eyeNoteOn, forKey: Key.eyeNoteOn) } }
    @Published var eyeNoteHour: Int = Standard.eyeNoteHour { didSet { defaults.set(eyeNoteHour, forKey: Key.eyeNoteHour) } }
    /// The day the question was last asked on: once a day.
    var eyeNoteAskedDay: String? {
        get { defaults.string(forKey: Key.eyeNoteAskedDay) }
        set { defaults.set(newValue, forKey: Key.eyeNoteAskedDay) }
    }

    // MARK: Breaks

    /// Nudge to look away after `breakMinutes` at the screen. Off unless you ask for it.
    @Published var breakNudgesOn: Bool = Standard.breakNudgesOn { didSet { defaults.set(breakNudgesOn, forKey: Key.breakNudgesOn) } }
    @Published var breakMinutes: Int = Standard.breakMinutes { didSet { defaults.set(breakMinutes, forKey: Key.breakMinutes) } }
    /// The length of a look-away break.
    @Published var breakSeconds: Int = Standard.breakSeconds { didSet { defaults.set(breakSeconds, forKey: Key.breakSeconds) } }
    /// After `longBreakEvery` short breaks, one of `longBreakMinutes` away from the screen.
    @Published var longBreakOn: Bool = Standard.longBreakOn { didSet { defaults.set(longBreakOn, forKey: Key.longBreakOn) } }
    @Published var longBreakEvery: Int = Standard.longBreakEvery { didSet { defaults.set(longBreakEvery, forKey: Key.longBreakEvery) } }
    @Published var longBreakMinutes: Int = Standard.longBreakMinutes { didSet { defaults.set(longBreakMinutes, forKey: Key.longBreakMinutes) } }

    /// A sound when a break starts (its banner's), and one when it ends. Both on unless
    /// you say otherwise: the end sound is what tells you to look back without looking.
    @Published var breakStartSound: Bool = Standard.breakStartSound { didSet { defaults.set(breakStartSound, forKey: Key.breakStartSound) } }
    @Published var breakEndSound: Bool = Standard.breakEndSound { didSet { defaults.set(breakEndSound, forKey: Key.breakEndSound) } }

    /// The four numbers above as the rules read them (see `BreakPlan`, which also keeps
    /// each one inside its range). Switching the long break off keeps its numbers.
    var breakPlan: BreakPlan {
        get {
            BreakPlan(workMinutes: breakMinutes, breakSeconds: breakSeconds,
                      longEvery: longBreakOn ? longBreakEvery : nil, longMinutes: longBreakMinutes)
        }
        set {
            breakMinutes = newValue.workMinutes
            breakSeconds = newValue.breakSeconds
            longBreakOn = newValue.longEvery != nil
            if let every = newValue.longEvery {
                longBreakEvery = every
                longBreakMinutes = newValue.longMinutes
            }
        }
    }

    // MARK: Remembered without being settings

    /// The Welcome window has been seen.
    var welcomed: Bool {
        get { defaults.bool(forKey: Key.welcomed) }
        set { defaults.set(newValue, forKey: Key.welcomed) }
    }

    /// "Follow my own rate" was offered in the panel and answered, one way or the other:
    /// it is offered once.
    @Published var ownRateOfferAnswered: Bool = false { didSet { defaults.set(ownRateOfferAnswered, forKey: Key.ownRateOfferAnswered) } }

    /// The offer is to be shown: the usual rate was measured UNDER the limit, so the app
    /// would say "Low" most of the time (`Baseline.limitAboveUsual`).
    var offersOwnRate: Bool {
        automaticLimit && !ownRateOfferAnswered && floor > Self.floorChoices.lowerBound
            && Baseline.limitAboveUsual(reference: reference, limit: limit)
    }

    /// "Follow my own rate": the floor goes down to where the limit is 70% of the usual rate.
    func followOwnRate() {
        if let reference { floor = min(floor, Baseline.floorFollowing(reference: reference)) }
        ownRateOfferAnswered = true
    }

    /// "Quiet", chosen in the panel: no banner and no sound before this. It survives a
    /// relaunch, like a pause.
    var quietUntil: Date? {
        get { defaults.object(forKey: Key.quietUntil) as? Date }
        set { defaults.set(newValue, forKey: Key.quietUntil) }
    }

    /// Today's look-away breaks, counted: they survive a relaunch.
    var breakTally: BreakTally? {
        get { defaults.data(forKey: Key.breakTally).flatMap { try? JSONDecoder().decode(BreakTally.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.breakTally) }
    }

    /// The pause in force when the app was last running: a pause survives a relaunch.
    var pause: PauseState {
        get {
            defaults.bool(forKey: Key.paused) ? .paused(until: defaults.object(forKey: Key.pausedUntil) as? Date) : .running
        }
        set {
            defaults.set(newValue != .running, forKey: Key.paused)
            defaults.set(newValue.end, forKey: Key.pausedUntil)
        }
    }

    /// What each choice is before anyone chose: read by `init` for a key that was never
    /// stored, and by `resetChoices`. Written once, so that the two cannot drift apart.
    enum Standard {
        static let showRateInMenuBar = true
        static let orangeRateWhenLow = true
        static let liveViewSound = false
        static let pauseOnBattery = false
        static let pauseInLowPower = false
        static let effort = Effort.standard
        static let quietDuringCalls = false
        static let workingHoursOn = false
        static let largerText = false
        static let summaryOn = false
        static let summaryHour = 17
        static let eyeNoteOn = false
        static let eyeNoteHour = 17
        static var workStart: TimeOfDay { WorkingHours.usual.start }
        static var workEnd: TimeOfDay { WorkingHours.usual.end }
        static var workDays: Set<Int> { WorkingHours.usual.weekdays }
        static let blinkBack = true
        static let remindersOn = true
        static let automaticLimit = true
        static var floor: Int { PublishedRates.startingFloor }
        static let breakNudgesOn = false
        /// The classic 20-20-20, with no long break.
        static let breakMinutes = 20
        static let breakSeconds = 20
        static let longBreakOn = false
        static let longBreakEvery = 3
        static let longBreakMinutes = 5
        static let breakStartSound = true
        static let breakEndSound = true
        static let blinkBreakShortcut: ShortcutChoice? = nil
        static let cameraID: String? = nil
    }

    /// ONE LINE PER CHOICE: the property, its standard, and how its stored value is read.
    /// `init` reads every choice through it, "Reset to Defaults" puts each back, and
    /// `hasChoices` compares each. Those were three lists written by hand, which had to
    /// name exactly the same thirty choices; nothing checked that they did.
    private struct Choice {
        let load: @MainActor (Preferences, UserDefaults) -> Void
        let reset: @MainActor (Preferences) -> Void
        let isStandard: @MainActor (Preferences) -> Bool

        /// `read`: the stored value; nil when none was stored, or it cannot be read (one
        /// written by a later version): the choice then stays at its standard.
        init<Value: Equatable>(_ path: ReferenceWritableKeyPath<Preferences, Value>, _ standard: Value,
                               read: @escaping (UserDefaults) -> Value?) {
            load = { preferences, defaults in if let value = read(defaults) { preferences[keyPath: path] = value } }
            reset = { $0[keyPath: path] = standard }
            isStandard = { $0[keyPath: path] == standard }
        }

        static func bool(_ path: ReferenceWritableKeyPath<Preferences, Bool>, _ key: String, _ standard: Bool) -> Choice {
            Choice(path, standard) { $0.object(forKey: key) as? Bool }
        }

        static func int(_ path: ReferenceWritableKeyPath<Preferences, Int>, _ key: String, _ standard: Int,
                        within range: ClosedRange<Int>? = nil) -> Choice {
            Choice(path, standard) { defaults in
                (defaults.object(forKey: key) as? Int).map { value in range.map { min(max(value, $0.lowerBound), $0.upperBound) } ?? value }
            }
        }

        /// A time of day, kept as minutes since midnight.
        static func time(_ path: ReferenceWritableKeyPath<Preferences, TimeOfDay>, _ key: String, _ standard: TimeOfDay) -> Choice {
            Choice(path, standard) { ($0.object(forKey: key) as? Int).map { TimeOfDay(hour: $0 / 60, minute: $0 % 60) } }
        }
    }

    private static let choices: [Choice] = [
        .bool(\.showRateInMenuBar, Key.showRate, Standard.showRateInMenuBar),
        .bool(\.orangeRateWhenLow, Key.orangeWhenLow, Standard.orangeRateWhenLow),
        .bool(\.liveViewSound, Key.liveViewSound, Standard.liveViewSound),
        .bool(\.pauseOnBattery, Key.pauseOnBattery, Standard.pauseOnBattery),
        .bool(\.pauseInLowPower, Key.pauseInLowPower, Standard.pauseInLowPower),
        Choice(\.effort, Standard.effort) { $0.string(forKey: Key.effort).flatMap(Effort.init(rawValue:)) },
        .bool(\.quietDuringCalls, Key.quietDuringCalls, Standard.quietDuringCalls),
        Choice(\.blinkBreakShortcut, Standard.blinkBreakShortcut) {
            $0.string(forKey: Key.blinkBreakShortcut).flatMap(ShortcutChoice.init(rawValue:)).map { Optional($0) }
        },
        .bool(\.largerText, Key.largerText, Standard.largerText),
        .bool(\.summaryOn, Key.summaryOn, Standard.summaryOn),
        .int(\.summaryHour, Key.summaryHour, Standard.summaryHour, within: 0...23),
        .bool(\.eyeNoteOn, Key.eyeNoteOn, Standard.eyeNoteOn),
        .int(\.eyeNoteHour, Key.eyeNoteHour, Standard.eyeNoteHour, within: 0...23),
        .bool(\.workingHoursOn, Key.workingHoursOn, Standard.workingHoursOn),
        .time(\.workStart, Key.workStart, Standard.workStart),
        .time(\.workEnd, Key.workEnd, Standard.workEnd),
        Choice(\.workDays, Standard.workDays) { ($0.array(forKey: Key.workDays) as? [Int]).map { Set($0.filter((1...7).contains)) } },
        .bool(\.blinkBack, Key.blinkBack, Standard.blinkBack),
        .bool(\.remindersOn, Key.remindersOn, Standard.remindersOn),
        .bool(\.automaticLimit, Key.automaticLimit, Standard.automaticLimit),
        .int(\.floor, Key.floor, Standard.floor),
        .bool(\.breakNudgesOn, Key.breakNudgesOn, Standard.breakNudgesOn),
        // Whoever chose a time before the other numbers existed keeps it, with the classic
        // 20 seconds and no long break: what the app did until then.
        .int(\.breakMinutes, Key.breakMinutes, Standard.breakMinutes),
        .int(\.breakSeconds, Key.breakSeconds, Standard.breakSeconds),
        .bool(\.longBreakOn, Key.longBreakOn, Standard.longBreakOn),
        .int(\.longBreakEvery, Key.longBreakEvery, Standard.longBreakEvery),
        .int(\.longBreakMinutes, Key.longBreakMinutes, Standard.longBreakMinutes),
        .bool(\.breakStartSound, Key.breakStartSound, Standard.breakStartSound),
        .bool(\.breakEndSound, Key.breakEndSound, Standard.breakEndSound),
        Choice(\.cameraID, Standard.cameraID) { $0.string(forKey: Key.cameraID).map { Optional($0) } },
    ]

    /// "Reset to Defaults": every CHOICE goes back to what it was on the first day.
    ///
    /// What is not a choice stays: your usual rate (it was measured, and measuring it
    /// again takes days), the history, the model and its recordings, the routines and
    /// their log, a pause or a Quiet in force, today's count of breaks, and the fact that
    /// the welcome was seen. Start at login is kept by macOS, not here, and stays too.
    /// The camera goes back to Automatic through `MonitorModel.resetChoices`, which also
    /// tells the camera.
    func resetChoices() {
        Self.choices.forEach { $0.reset(self) }
        // The lowest limit is back where it started, so "Follow My Own Rate" may be offered again.
        ownRateOfferAnswered = false
    }

    /// Whether any choice differs from its default: "Reset to Defaults" has something to do.
    var hasChoices: Bool {
        !Self.choices.allSatisfy { $0.isStandard(self) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Every choice starts at its standard; what was stored takes its place.
        Self.choices.forEach { $0.load(self, defaults) }
        ownRateOfferAnswered = defaults.bool(forKey: Key.ownRateOfferAnswered)

        let stored = defaults.dictionary(forKey: Key.reference)
        if let rate = stored?["rate"] as? Double, let measuredOn = stored?["measuredOn"] as? Date,
           let minutes = stored?["minutes"] as? Int {
            reference = Reference(rate: rate, measuredOn: measuredOn, minutes: minutes)
        } else {
            reference = nil
        }
    }

    /// An empty store that is never the user's: for screenshots.
    static func temporary() -> Preferences {
        let name = "local.blinkmonitor.temporary"
        UserDefaults().removePersistentDomain(forName: name)
        // No falling back to the user's own settings: made-up choices must never reach them.
        guard let store = UserDefaults(suiteName: name) else { preconditionFailure("No settings store named \(name)") }
        return Preferences(defaults: store)
    }
}

