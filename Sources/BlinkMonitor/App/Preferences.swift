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
        static let blinkBack = "blinkBack"
        static let remindersOn = "remindersOn"
        static let automaticLimit = "automaticLimit"
        static let floor = "threshold"            // its name in the first version
        static let reference = "reference"
        static let breakNudgesOn = "breakNudgesOn"
        static let breakMinutes = "breakMinutes"
        static let welcomed = "welcomed"
        static let paused = "paused"
        static let pausedUntil = "pausedUntil"
    }

    /// The choices offered for "nudge me after ... at the screen".
    static let breakChoices = [20, 30, 45, 60]

    private let defaults: UserDefaults

    // MARK: General

    /// The menu bar shows the rate next to the eye (off: the eye alone).
    @Published var showRateInMenuBar: Bool { didSet { defaults.set(showRateInMenuBar, forKey: Key.showRate) } }

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

    // MARK: Remembered without being settings

    /// The Welcome window has been seen.
    var welcomed: Bool {
        get { defaults.bool(forKey: Key.welcomed) }
        set { defaults.set(newValue, forKey: Key.welcomed) }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showRateInMenuBar = defaults.object(forKey: Key.showRate) as? Bool ?? true
        blinkBack = defaults.object(forKey: Key.blinkBack) as? Bool ?? true
        remindersOn = defaults.object(forKey: Key.remindersOn) as? Bool ?? true
        automaticLimit = defaults.object(forKey: Key.automaticLimit) as? Bool ?? true
        floor = defaults.object(forKey: Key.floor) as? Int ?? PublishedRates.startingFloor
        breakNudgesOn = defaults.bool(forKey: Key.breakNudgesOn)
        breakMinutes = defaults.object(forKey: Key.breakMinutes) as? Int ?? Self.breakChoices[0]

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
