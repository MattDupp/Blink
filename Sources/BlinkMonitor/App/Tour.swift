import Foundation

/// The demo walking through its own screens: what `--demo --tour` plays.
///
///     BlinkMonitor --demo --tour [--tour-pace=<seconds>]
///
/// It is there for filming. Nobody has to click while the screen is being recorded, the
/// order is the same at every take, and the demo shows the whole app without a face: its
/// eyes are drawn, its history is made up, and it writes nothing to the user's files.
/// Each step is written to the log as it begins, so a take can be checked without
/// watching it (`/usr/bin/log show --predicate 'subsystem == "local.blinkmonitor"'`).
///
/// The list is a value, in one place: the order and the lengths can be read, changed and
/// tested without starting the app. `AppDelegate.playTour` does what each step names.
enum Tour {

    enum Step: String, CaseIterable {
        /// The panel under the menu-bar eye: the rate, today, the last hour.
        case panel
        /// A blink break, counted on the demo's eyes.
        case blinkBreak = "blink-break"
        /// History: the last seven days, then an earlier week, then back.
        case history
        case historyEarlierWeek = "history-earlier-week"
        case historyBack = "history-back"
        /// Settings, tab after tab.
        case settingsGeneral = "settings-general"
        case settingsBlinkRate = "settings-blink-rate"
        case settingsBreaks = "settings-breaks"
        case settingsRoutines = "settings-routines"
        case settingsPrivacy = "settings-privacy"
        case settingsAbout = "settings-about"
        /// Live View: the drawn eyes, the curve, each blink as it is counted.
        case liveView = "live-view"
        /// Back to the panel, where it started.
        case end

        /// How long the step stays on screen, as a multiple of the pace.
        var beats: Double {
            switch self {
            case .panel, .history, .liveView: return 2
            case .blinkBreak: return 3
            case .end: return 1
            default: return 1
            }
        }
    }

    /// Seconds for one beat, unless `--tour-pace` says otherwise. Kept between 1 and 30:
    /// a tour must neither flicker nor look frozen.
    static let usualPace = 4.0

    static func pace(asked: String?) -> Double {
        guard let asked, let seconds = Double(asked) else { return usualPace }
        return min(max(seconds, 1), 30)
    }

    /// The whole tour: each step with its length in seconds.
    static func plan(pace: Double = usualPace) -> [(step: Step, seconds: Double)] {
        Step.allCases.map { ($0, $0.beats * pace) }
    }

    static func length(pace: Double = usualPace) -> Double {
        plan(pace: pace).reduce(0) { $0 + $1.seconds }
    }
}
