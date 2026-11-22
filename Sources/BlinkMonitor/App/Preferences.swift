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
        static let quietDuringCalls = "quietDuringCalls"
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
    @Published var showRateInMenuBar: Bool { didSet { defaults.set(showRateInMenuBar, forKey: Key.showRate) } }
    /// A short sound at every counted blink while Live View is open. Off unless chosen,
    /// and kept: it was on at every opening, and the Mac popped at each blink.
    @Published var liveViewSound: Bool { didSet { defaults.set(liveViewSound, forKey: Key.liveViewSound) } }
    /// Counting rests while the Mac runs on its battery, and while Low Power Mode is on
    /// (`EnergyPause`). Both off unless chosen.
    @Published var pauseOnBattery: Bool { didSet { defaults.set(pauseOnBattery, forKey: Key.pauseOnBattery) } }
    @Published var pauseInLowPower: Bool { didSet { defaults.set(pauseInLowPower, forKey: Key.pauseInLowPower) } }
    /// No banner and no sound while the microphone is in use, which is most likely a call.
    @Published var quietDuringCalls: Bool { didSet { defaults.set(quietDuringCalls, forKey: Key.quietDuringCalls) } }
    /// "Quiet outside working hours": off unless chosen. The two times are minutes since
    /// midnight, the days are 1 = Sunday ... 7 = Saturday (`WorkingHours`).
    @Published var workingHoursOn: Bool { didSet { defaults.set(workingHoursOn, forKey: Key.workingHoursOn) } }
    @Published var workStart: TimeOfDay { didSet { defaults.set(workStart.hour * 60 + workStart.minute, forKey: Key.workStart) } }
    @Published var workEnd: TimeOfDay { didSet { defaults.set(workEnd.hour * 60 + workEnd.minute, forKey: Key.workEnd) } }
    @Published var workDays: Set<Int> { didSet { defaults.set(workDays.sorted(), forKey: Key.workDays) } }
    /// The hours as the gate reads them; nil while the switch is off.
    var workingHours: WorkingHours? {
        workingHoursOn ? WorkingHours(start: workStart, end: workEnd, weekdays: workDays) : nil
    }
    /// The camera the user chose, as macOS knows it. Nil: Automatic (`CameraChoice`).
    @Published var cameraID: String? { didSet { defaults.set(cameraID, forKey: Key.cameraID) } }
    /// The rate in the menu bar is written in orange while it is low. The badge on the
    /// eye alone was nearly invisible (audit of 22 November 2026, item 2.17).
    @Published var orangeRateWhenLow: Bool { didSet { defaults.set(orangeRateWhenLow, forKey: Key.orangeWhenLow) } }

    /// The eye in the menu bar closes for a moment each time you blink.
    @Published var blinkBack: Bool { didSet { defaults.set(blinkBack, forKey: Key.blinkBack) } }

    // MARK: Reminders

    @Published var remindersOn: Bool { didSet { defaults.set(remindersOn, forKey: Key.remindersOn) } }

    /// The limit follows your own reference (see `Baseline`); off: the limit is `floor`.
    @Published var automaticLimit: Bool { didSet { defaults.set(automaticLimit, forKey: Key.automaticLimit) } }

    /// The limit you set by hand, in blinks a minute. With an automatic limit it is the
    /// floor: the limit never goes under it. Where it starts is `PublishedRates.startingFloor`:
    /// a starting point for you to adjust, not a medical limit.
    @Published var floor: Int { didSet { defaults.set(floor, forKey: Key.floor) } }

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

    // MARK: Breaks

    /// Nudge to look away after `breakMinutes` at the screen. Off unless you ask for it.
    @Published var breakNudgesOn: Bool { didSet { defaults.set(breakNudgesOn, forKey: Key.breakNudgesOn) } }
    @Published var breakMinutes: Int { didSet { defaults.set(breakMinutes, forKey: Key.breakMinutes) } }
    /// The length of a look-away break.
    @Published var breakSeconds: Int { didSet { defaults.set(breakSeconds, forKey: Key.breakSeconds) } }
    /// After `longBreakEvery` short breaks, one of `longBreakMinutes` away from the screen.
    @Published var longBreakOn: Bool { didSet { defaults.set(longBreakOn, forKey: Key.longBreakOn) } }
    @Published var longBreakEvery: Int { didSet { defaults.set(longBreakEvery, forKey: Key.longBreakEvery) } }
    @Published var longBreakMinutes: Int { didSet { defaults.set(longBreakMinutes, forKey: Key.longBreakMinutes) } }

    /// A sound when a break starts (its banner's), and one when it ends. Both on unless
    /// you say otherwise: the end sound is what tells you to look back without looking.
    @Published var breakStartSound: Bool { didSet { defaults.set(breakStartSound, forKey: Key.breakStartSound) } }
    @Published var breakEndSound: Bool { didSet { defaults.set(breakEndSound, forKey: Key.breakEndSound) } }

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
    @Published var ownRateOfferAnswered: Bool { didSet { defaults.set(ownRateOfferAnswered, forKey: Key.ownRateOfferAnswered) } }

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
        static let quietDuringCalls = false
        static let workingHoursOn = false
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
    }

    /// "Reset to Defaults": every CHOICE goes back to what it was on the first day.
    ///
    /// What is not a choice stays: your usual rate (it was measured, and measuring it
    /// again takes days), the history, the model and its recordings, the routines and
    /// their log, a pause or a Quiet in force, today's count of breaks, and the fact that
    /// the welcome was seen. Start at login is kept by macOS, not here, and stays too.
    /// The camera goes back to Automatic through `MonitorModel.resetChoices`, which also
    /// tells the camera.
    func resetChoices() {
        showRateInMenuBar = Standard.showRateInMenuBar
        orangeRateWhenLow = Standard.orangeRateWhenLow
        liveViewSound = Standard.liveViewSound
        pauseOnBattery = Standard.pauseOnBattery
        pauseInLowPower = Standard.pauseInLowPower
        quietDuringCalls = Standard.quietDuringCalls
        workingHoursOn = Standard.workingHoursOn
        workStart = Standard.workStart
        workEnd = Standard.workEnd
        workDays = Standard.workDays
        blinkBack = Standard.blinkBack
        remindersOn = Standard.remindersOn
        automaticLimit = Standard.automaticLimit
        floor = Standard.floor
        // The lowest limit is back where it started, so "Follow My Own Rate" may be offered again.
        ownRateOfferAnswered = false
        breakNudgesOn = Standard.breakNudgesOn
        breakMinutes = Standard.breakMinutes
        breakSeconds = Standard.breakSeconds
        longBreakOn = Standard.longBreakOn
        longBreakEvery = Standard.longBreakEvery
        longBreakMinutes = Standard.longBreakMinutes
        breakStartSound = Standard.breakStartSound
        breakEndSound = Standard.breakEndSound
        cameraID = nil
    }

    /// Whether any choice differs from its default: "Reset to Defaults" has something to do.
    var hasChoices: Bool {
        showRateInMenuBar != Standard.showRateInMenuBar || orangeRateWhenLow != Standard.orangeRateWhenLow
            || liveViewSound != Standard.liveViewSound || pauseOnBattery != Standard.pauseOnBattery
            || pauseInLowPower != Standard.pauseInLowPower || quietDuringCalls != Standard.quietDuringCalls
            || blinkBack != Standard.blinkBack || remindersOn != Standard.remindersOn
            || automaticLimit != Standard.automaticLimit || floor != Standard.floor
            || breakNudgesOn != Standard.breakNudgesOn || breakMinutes != Standard.breakMinutes
            || breakSeconds != Standard.breakSeconds || longBreakOn != Standard.longBreakOn
            || longBreakEvery != Standard.longBreakEvery || longBreakMinutes != Standard.longBreakMinutes
            || breakStartSound != Standard.breakStartSound || breakEndSound != Standard.breakEndSound
            || cameraID != nil
            || workingHoursOn != Standard.workingHoursOn || workStart != Standard.workStart
            || workEnd != Standard.workEnd || workDays != Standard.workDays
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ standard: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? standard }
        func int(_ key: String, _ standard: Int) -> Int { defaults.object(forKey: key) as? Int ?? standard }
        showRateInMenuBar = bool(Key.showRate, Standard.showRateInMenuBar)
        orangeRateWhenLow = bool(Key.orangeWhenLow, Standard.orangeRateWhenLow)
        liveViewSound = bool(Key.liveViewSound, Standard.liveViewSound)
        cameraID = defaults.string(forKey: Key.cameraID)
        pauseOnBattery = bool(Key.pauseOnBattery, Standard.pauseOnBattery)
        pauseInLowPower = bool(Key.pauseInLowPower, Standard.pauseInLowPower)
        quietDuringCalls = bool(Key.quietDuringCalls, Standard.quietDuringCalls)
        workingHoursOn = bool(Key.workingHoursOn, Standard.workingHoursOn)
        func time(_ key: String, _ standard: TimeOfDay) -> TimeOfDay {
            (defaults.object(forKey: key) as? Int).map { TimeOfDay(hour: $0 / 60, minute: $0 % 60) } ?? standard
        }
        workStart = time(Key.workStart, Standard.workStart)
        workEnd = time(Key.workEnd, Standard.workEnd)
        workDays = (defaults.array(forKey: Key.workDays) as? [Int]).map { Set($0.filter((1...7).contains)) } ?? Standard.workDays
        blinkBack = bool(Key.blinkBack, Standard.blinkBack)
        remindersOn = bool(Key.remindersOn, Standard.remindersOn)
        automaticLimit = bool(Key.automaticLimit, Standard.automaticLimit)
        floor = int(Key.floor, Standard.floor)
        ownRateOfferAnswered = defaults.bool(forKey: Key.ownRateOfferAnswered)
        breakNudgesOn = bool(Key.breakNudgesOn, Standard.breakNudgesOn)
        // Whoever chose a time before the other numbers existed keeps it, with the classic
        // 20 seconds and no long break: what the app did until then.
        breakMinutes = int(Key.breakMinutes, Standard.breakMinutes)
        breakSeconds = int(Key.breakSeconds, Standard.breakSeconds)
        longBreakOn = bool(Key.longBreakOn, Standard.longBreakOn)
        longBreakEvery = int(Key.longBreakEvery, Standard.longBreakEvery)
        longBreakMinutes = int(Key.longBreakMinutes, Standard.longBreakMinutes)
        breakStartSound = bool(Key.breakStartSound, Standard.breakStartSound)
        breakEndSound = bool(Key.breakEndSound, Standard.breakEndSound)

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
        return Preferences(defaults: UserDefaults(suiteName: name) ?? .standard)
    }
}
