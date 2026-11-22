import SwiftUI
import BlinkCore
import BlinkUI

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

    /// The rate as written in the menu bar: "13", or "--" when there is none to show.
    var rateText: String {
        RateReadout.text(rate)
    }

    /// The text next to the menu-bar symbol.
    var menuBarText: String {
        switch self {
        case .starting, .failed, .paused, .cameraSilent, .settingUp: return ""
        case .cameraRefused, .needsSetup: return "!"
        case .noFace, .watching, .low: return rateText
        }
    }

    var tooltip: String {
        switch self {
        case .starting: return "Blink Monitor is starting"
        case .needsSetup: return "Blink Monitor: setup is not finished"
        case .settingUp: return "Blink Monitor is being set up"
        case .cameraRefused: return "Blink Monitor: camera access refused"
        case .failed(let reason): return "Blink Monitor: \(reason)"
        case .paused(let until): return "Blink Monitor is paused" + (until.map { " until " + Format.pauseEnd($0) } ?? "")
        case .cameraSilent: return "Blink Monitor: the camera is not sending pictures"
        case .noFace: return "Blink Monitor: no face in view"
        case .watching: return "Blinks per minute, over the last minute"
        case .low(_, let recent):
            return String(format: "You blink too little: %.0f a minute over the last 3 minutes", recent)
        }
    }

    /// One or two words, for the pill in the panel.
    var label: String {
        switch self {
        case .starting: return "Starting"
        case .needsSetup, .settingUp: return "Setup"
        case .cameraRefused: return "No camera"
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
        case .cameraRefused: return "No camera"
        case .failed: return "Not counting"
        case .paused: return "Paused"
        case .cameraSilent: return "No picture"
        case .noFace: return "No face"
        case .watching(let rate), .low(let rate, _): return rate == nil ? "Starting" : nil
        }
    }

    /// One sentence under the rate, in the panel. `limit`: the limit in force.
    func explanation(limit: Int) -> String {
        switch self {
        case .starting:
            return "Starting the camera."
        case .needsSetup:
            return "Blink Monitor has no model of your eyes yet, so nothing is counted. Setup takes about six minutes."
        case .settingUp(.checkingCamera):
            return "Setup is checking the camera. Nothing is counted meanwhile."
        case .settingUp(.recording):
            return "Setup is recording your eyes. Nothing is counted meanwhile."
        case .settingUp(.training):
            return "Your model is being trained. Nothing is counted meanwhile."
        case .settingUp(.testing):
            return "Setup is testing your model. Nothing is counted meanwhile."
        case .cameraRefused:
            return "Camera access was refused. Allow Blink Monitor in System Settings > Privacy & Security > Camera. "
                + "If nothing changes after that, quit Blink Monitor and open it again."
        case .failed(let reason):
            return reason
        case .paused(let until):
            return "The camera is off until " + (until.map { Format.pauseEnd($0) } ?? "you resume") + ". Nothing is being counted."
        case .cameraSilent:
            return "The camera is not sending pictures, so nothing is counted. With the lid closed that is expected; otherwise it is started again by itself."
        case .noFace:
            return "No face in view, so this time is not counted. If you are here: face the camera and check the light."
        case .watching(let rate):
            return rate == nil ? "Your rate appears after 20 seconds." : "Your rate over the last minute. Your limit is \(limit)."
        case .low(_, let recent):
            return String(format: "About %.0f a minute over the last 3 minutes. A blink break helps: ten slow, full blinks.", recent)
        }
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
        return "Learning your usual rate: \(progress) Until then the limit is \(limit)."
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
            return "No camera was found, so nothing is counted. Plug one in, or open the lid, then try again."
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
