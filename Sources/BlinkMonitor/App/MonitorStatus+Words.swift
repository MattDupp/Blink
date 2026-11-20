import SwiftUI
import BlinkCore
import BlinkUI

/// How each situation is worded and drawn. `MonitorStatus` (in BlinkCore) decides WHAT the
/// situation is; this is the only place that decides how the app says it.
extension MonitorStatus {

    /// The SF Symbol of the menu-bar item.
    var symbol: String {
        switch self {
        case .starting, .noFace, .watching: return "eye"
        case .cameraRefused, .paused: return "eye.slash"
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
        case .starting, .failed, .paused: return ""
        case .cameraRefused: return "!"
        case .noFace, .watching, .low: return rateText
        }
    }

    var tooltip: String {
        switch self {
        case .starting: return "Blink Monitor is starting"
        case .cameraRefused: return "Blink Monitor: camera access refused"
        case .failed(let reason): return "Blink Monitor: \(reason)"
        case .paused(let until): return "Blink Monitor is paused" + (until.map { " until " + Format.pauseEnd($0) } ?? "")
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
        case .cameraRefused: return "No camera"
        case .failed: return "Problem"
        case .paused: return "Paused"
        case .noFace: return "No face"
        case .watching: return "Watching"
        case .low: return "Low"
        }
    }

    var tint: Color {
        switch self {
        case .watching: return .green
        case .low: return .orange
        case .cameraRefused, .failed: return .red
        case .starting, .paused, .noFace: return .secondary
        }
    }

    /// One sentence under the rate, in the panel.
    var explanation: String {
        switch self {
        case .starting:
            return "Starting the camera."
        case .cameraRefused:
            return "Camera access was refused. Allow Blink Monitor in System Settings > Privacy & Security > Camera, then open it again."
        case .failed(let reason):
            return reason
        case .paused(let until):
            return "The camera is off until " + (until.map { Format.pauseEnd($0) } ?? "you resume") + ". Nothing is being counted."
        case .noFace:
            return "Nobody in front of the camera: this time is not counted."
        case .watching(let rate):
            return rate == nil ? "A rate appears after 20 seconds of watching." : "Over the last minute your eyes were watched."
        case .low(_, let recent):
            return String(format: "About %.0f a minute over the last 3 minutes. A blink break helps: ten slow, full blinks.", recent)
        }
    }
}
