import SwiftUI
import BlinkCore
import BlinkUI

/// What the app says of itself, under its name.
enum AppWords {
    /// It ended "when you forget to.", and the last word attached itself to "count".
    static let tagline = "Counts your blinks, and tells you when you forget to blink."
}

/// The low rate, said once. The banner, the panel and the menu bar's tooltip each had
/// their own sentence for it, and the panel's stood under a large number that measures
/// something else: the last minute, where "low" is about the last three.
enum LowRateWords {
    /// "under your limit of 10 over the last 3 minutes": the fact, to put after "Low: ".
    static func fact(limit: Int, minutes: Int = ReminderPolicy().windowMinutes) -> String {
        "under your limit of \(limit) over the last \(Format.count(minutes, "minute"))"
    }

    /// The same as a sentence: "Under your limit of 10 over the last 3 minutes."
    static func sentence(limit: Int) -> String {
        let fact = fact(limit: limit)
        return fact.prefix(1).uppercased() + fact.dropFirst() + "."
    }
}

/// How each situation is worded and drawn. `MonitorStatus` (in BlinkCore) decides WHAT the
/// situation is; this is the only place that decides how the app says it.
extension MonitorStatus {

    /// The SF Symbol of the menu-bar item.
    var symbol: String {
        switch self {
        case .starting, .noFace, .watching, .settingUp: return "eye"
        case .cameraRefused, .paused, .cameraSilent, .needsSetup: return "eye.slash"
        case .failed: return "exclamationmark.triangle"
        case .low: return "eye.trianglebadge.exclamationmark"
        }
    }

    /// The rate as written in the menu bar: "13", or a dash when there is none to show.
    var rateText: String {
        RateReadout.text(rate)
    }

    /// The text next to the menu-bar symbol.
    var menuBarText: String {
        switch self {
        case .starting, .failed, .paused, .cameraSilent, .settingUp: return ""
        case .cameraRefused, .needsSetup: return "!"
        case .noFace, .watching, .low: return Self.slot(rateText)
        }
    }

    /// The rate in a slot two digits wide: "9" took less room than "10", so the item, and
    /// every item to its left, moved each time the rate crossed ten. A figure space is as
    /// wide as a digit (the menu bar draws the number with digits of one width).
    static func slot(_ text: String) -> String {
        text.count >= 2 ? text : String(repeating: "\u{2007}", count: 2 - text.count) + text
    }

    /// `limit`: the limit in force, said when the rate is under it.
    func tooltip(limit: Int) -> String {
        switch self {
        case .starting: return "Blink Monitor is starting"
        case .needsSetup: return "Blink Monitor: setup is not finished"
        case .settingUp: return "Blink Monitor is being set up"
        case .cameraRefused: return "Blink Monitor: camera access refused"
        case .failed(let reason): return "Blink Monitor: \(reason)"
        case .paused(let until): return "Blink Monitor is paused" + (until.map { " until " + Format.pauseEnd($0) } ?? "")
        case .cameraSilent: return "Blink Monitor: the camera is not sending pictures"
        case .noFace: return "Blink Monitor: no face in view"
        case .watching: return "Blinks a minute, over the last minute"
        case .low: return "Low: " + LowRateWords.fact(limit: limit)
        }
    }

    /// One or two words, for the pill in the panel.
    var label: String {
        switch self {
        case .starting: return "Starting"
        case .needsSetup, .settingUp: return "Setup"
        case .cameraRefused: return "Camera blocked"
        case .failed: return "Problem"
        case .paused: return "Paused"
        case .cameraSilent: return "No picture"
        case .noFace: return "No face"
        case .watching: return "Watching"
        case .low: return "Low"
        }
    }

    var tint: Color {
        switch self {
        case .watching: return .green
        case .low, .cameraSilent, .needsSetup: return .orange
        case .cameraRefused, .failed: return .red
        case .settingUp: return .accentColor
        case .starting, .paused, .noFace: return .secondary
        }
    }

    /// The state in a word or two, written LARGE in the panel where the rate would be,
    /// when there is no rate to write. Nil when the rate is shown. Before this, two grey
    /// dashes stood there and the largest type on the panel said nothing.
    var headline: String? {
        switch self {
        case .starting: return "Starting"
        case .needsSetup: return "Not set up"
        case .settingUp: return "Setting up"
        case .cameraRefused: return "Camera blocked"
        case .failed: return "Not counting"
        case .paused: return "Paused"
        case .cameraSilent: return "No picture"
        case .noFace: return "No face"
        case .watching(let rate), .low(let rate, _): return rate == nil ? "Starting" : nil
        }
    }

    /// One sentence under the rate, in the panel. `limit`: the limit in force.
    /// `timer`: the routine whose timer holds the pause (a mask on the eyes), if any.
    /// `energy`: counting rests to save energy (`EnergyPause`), which is not a pause.
    func explanation(limit: Int, timer: String? = nil, energy: EnergyPause.Reason? = nil, camera: CameraPlace = .lid) -> String {
        if case .paused = self, let energy {
            switch energy {
            case .battery:
                return "Resting on battery, as chosen in Settings: the camera is off and nothing is counted. "
                    + "It comes back when the Mac is plugged in. Resume counts anyway."
            case .lowPower:
                return "Resting while Low Power Mode is on, as chosen in Settings: the camera is off and nothing is counted. Resume counts anyway."
            }
        }
        // During a timer the pause is not an ordinary one: the eyes are covered, and
        // Resume would turn the camera on under the mask.
        if case .paused(let until?) = self, let timer {
            return "Paused for \(timer), until \(Format.pauseEnd(until)). The camera comes back by itself when the timer ends."
        }
        switch self {
        case .starting:
            return "Starting the camera."
        case .needsSetup:
            return "Blink Monitor has not learned your eyes yet, so nothing is counted. Setup takes about 8 minutes."
        case .settingUp(.checkingCamera):
            return "Setup is checking the camera. Nothing is counted meanwhile."
        case .settingUp(.recording):
            return "Setup is recording your eyes. Nothing is counted meanwhile."
        case .settingUp(.training):
            return "Your model is being trained. Nothing is counted meanwhile."
        case .settingUp(.testing):
            return "Setup is testing your model. Nothing is counted meanwhile."
        case .cameraRefused:
            return CameraNote.blocked(appName: "Blink Monitor") + " " + CameraNote.unblock(appName: "Blink Monitor")
                + " If nothing changes after that, quit Blink Monitor and open it again."
        case .failed(let reason):
            return reason
        case .paused(let until):
            // What stops and what goes on: routines do not need the camera.
            return "The camera is off until " + (until.map { Format.pauseEnd($0) } ?? "you resume")
                + ". Nothing is counted, and no blink reminder or look-away break comes. Routines still remind you."
        case .cameraSilent:
            return CameraNote.silent + " Nothing is counted. " + CameraNote.silentWhy(camera)
        case .noFace:
            return "No face in view, so this time is not counted. If you are here: face the camera and check the light."
        case .watching(let rate):
            return rate == nil ? "Your rate appears after 20 seconds." : "Your rate over the last minute. Your limit is \(limit)."
        case .low:
            return LowRateWords.sentence(limit: limit) + " Try a blink break: ten slow, full blinks."
        }
    }
}

/// What the menu-bar item shows beside the eye and the rate: one small symbol for each
/// thing that is going on, each said in the tooltip. Before, a "•" meant "a routine is
/// waiting", and a break, a quiet period or a timer showed nothing at all.
struct MenuBarMarks: Equatable {
    struct Routine: Equatable {
        var title: String
        var symbol: String
    }
    /// Routines waiting to be done.
    var waiting: [Routine] = []
    /// A look-away break is running.
    var onBreak = false
    /// Reminders are held until this moment.
    var quietUntil: Date?
    /// A routine's timer runs until this moment.
    var timerUntil: Date?

    /// The symbols to draw, in order.
    var symbols: [String] {
        var symbols: [String] = []
        if timerUntil != nil { symbols.append("timer") }
        if onBreak { symbols.append("eyes") }
        if quietUntil != nil { symbols.append("bell.slash") }
        // One routine shows its own symbol; several, one dot.
        if waiting.count == 1 { symbols.append(waiting[0].symbol) } else if waiting.count > 1 { symbols.append("circle.fill") }
        return symbols
    }

    /// The sentences the tooltip adds, each ending without a full stop.
    var sentences: [String] {
        var sentences: [String] = []
        if let timerUntil { sentences.append("Timer until \(Format.time(timerUntil))") }
        if onBreak { sentences.append("Look-away break") }
        if let quietUntil { sentences.append("Quiet until \(Format.pauseEnd(quietUntil))") }
        if !waiting.isEmpty { sentences.append("Waiting: " + waiting.map(\.title).joined(separator: ", ")) }
        return sentences
    }

    func tooltip(after status: String) -> String {
        ([status] + sentences).joined(separator: ". ")
    }
}

/// How far the app is from knowing your usual rate, said with what is left.
/// "50% done" stopped at 50% for the whole first day and gave no reason: the measure
/// needs three hours at the screen AND two different days.
enum CalibrationWords {
    static func line(_ calibration: Baseline.Calibration, limit: Int) -> String {
        let needed = Format.duration(Baseline.calibrationSeconds)
        let progress: String
        if calibration.secondsLeft > 0 {
            let done = "\(Format.duration(calibration.watchedSeconds)) of \(needed)"
            progress = calibration.daysLeft > 0
                ? "\(done), over \(Baseline.calibrationDays) days. It can finish tomorrow."
                : "\(done). \(Format.duration(max(60, calibration.secondsLeft))) to go."
        } else {
            progress = "\(needed) done, all on one day. It takes \(Baseline.calibrationDays) days: it finishes tomorrow."
        }
        return "Learning your usual rate: \(progress) Until then the limit is \(limit) a minute."
    }
}

/// Why counting could not start, in a sentence for a person. What the system said (a
/// Swift error, a path) goes to the log: `/usr/bin/log show --predicate 'subsystem == "local.blinkmonitor"'`.
enum StartFailure: Equatable {
    /// The model could not be read. `trainedHere`: it is the one the setup made.
    case model(trainedHere: Bool)
    case noCamera
    case camera
    /// The app was started with the camera left off (a developer looking at the windows).
    case cameraLeftOff

    var sentence: String {
        switch self {
        case .model(trainedHere: true):
            return "Your model could not be read from disk, so nothing is counted. Try again, or open the setup to train a new one: your recordings are kept."
        case .model(trainedHere: false):
            return "The model this copy of the app came with could not be read, so nothing is counted. Open the setup to train one on your eyes."
        case .noCamera:
            return "No camera was found, so nothing is counted. \(CameraNote.findOne(macHasLid: MacState.hasLid)), then try again."
        case .camera:
            return "The camera could not be started, so nothing is counted. Another app may be holding it. Try again in a moment."
        case .cameraLeftOff:
            return "The camera was left off when the app was started. Nothing is counted."
        }
    }

    /// The setup can make another model.
    var offersSetup: Bool {
        if case .model = self { return true }
        return false
    }
}

/// What the panel says while no banner may show, whatever the reason: one sentence, so
/// that the Quiet chosen in the panel and the time outside the working hours read alike.
enum QuietWords {
    static let effect = "no reminder, no break and no sound. Counting goes on."

    static func line(_ reason: BannerGate.QuietReason, now: Date) -> String {
        switch reason {
        case .chosen(let until):
            return "Quiet until \(Format.pauseEnd(until)): \(effect)"
        case .outsideHours(let until):
            let end = until.map { " until \(Format.ahead($0, from: now))" } ?? ""
            return "Quiet\(end), outside your working hours: \(effect) Set in Settings, General."
        }
    }

    /// The row in Settings.
    static let title = "Quiet outside working hours"
    static let detail = "No reminder, no look-away break, no routine and no sound outside these hours. Counting goes on, and the panel says when Quiet ends."
    /// Under the two times, when the first is not before the second.
    static let overnight = "These hours pass midnight. Each night belongs to the day it starts on."
}

/// The words of the optional summary of the day. It reports numbers; it does not judge
/// them and gives no advice.
enum SummaryWords {
    static let identifier = "day-summary"
    static let title = "Today so far"

    /// The banner's text, or nil for a day with nothing counted (no banner).
    static func body(_ digest: DayDigest, limit: Int) -> String? {
        var sentences: [String] = []
        switch digest.day {
        case .notAtScreen:
            return nil
        case .tooLittle(let seconds):
            sentences.append("\(Format.duration(seconds)) at the screen: too little to give a rate.")
        case .counted(let seconds, let rate, let aboveLimit):
            var sentence = "\(Format.duration(seconds)) at the screen, \(Format.rate(rate)) blinks a minute"
            if let aboveLimit { sentence += ", \(aboveLimit)% of the time above your limit of \(limit)" }
            sentences.append(sentence + ".")
        }
        if digest.breaksTaken > 0 { sentences.append("\(Format.count(digest.breaksTaken, "look-away break")) taken.") }
        if let week = digest.lastWeek {
            sentences.append("The seven days before: \(Format.duration(week.seconds)) at the screen, \(Format.rate(week.rate)) blinks a minute.")
        }
        return sentences.joined(separator: " ")
    }

    /// The rows in Settings.
    static let row = "A summary of the day"
    static let detail = "One silent banner a day, at the hour you choose, with the time at the screen and your rate. On Mondays it adds a line for the seven days before. A day with under 30 minutes at the screen gets no rate."
    static let hourRow = "Hour of the summary"

    /// Under the hour, when Quiet outside working hours would hold the banner back.
    static func heldBack(hour: Int) -> String {
        "At \(Format.hour(hour)) your working hours are over, and Quiet holds this banner back. Choose an hour inside them."
    }

    /// Would the working hours hold back a summary at this hour, on every chosen day?
    static func isHeldBack(hour: Int, by hours: WorkingHours?) -> Bool {
        guard let hours else { return false }
        let time = TimeOfDay(hour: hour)
        return hours.start < hours.end ? !(time >= hours.start && time < hours.end) : !(time >= hours.start || time < hours.end)
    }
}
