import Foundation

/// Where an app that needs the camera is in its life.
public enum Lifecycle: Equatable {
    case starting
    /// macOS refused the camera (System Settings > Privacy & Security > Camera).
    case cameraRefused
    case failed(String)
    case running
}

/// What the monitor is doing right now, as ONE value.
///
/// The menu bar, the panel and the camera view all describe the same situation in their
/// own words. The first version kept a copy of the description up to date by hand and
/// re-decided the situation in five places; the copies drifted (the panel ignored a
/// sleeping screen, a new threshold took a minute to show). Now the situation is decided
/// here, from the facts, each time it is asked - and every window words what this says.
public enum MonitorStatus: Equatable {
    case starting
    case cameraRefused
    case failed(String)
    /// The camera is off: you chose Pause, or the screen sleeps.
    case paused
    /// Nobody in front of the camera.
    case noFace
    /// `rate`: blinks a minute over the last minute watched (nil for the first 20 s).
    case watching(rate: Double?)
    /// Blinking too little: `recent` is the rate over the last three minutes.
    case low(rate: Double?, recent: Double)

    public init(lifecycle: Lifecycle, paused: Bool, faceFound: Bool, rate: Double?, recentLowRate: Double?) {
        switch lifecycle {
        case .starting: self = .starting
        case .cameraRefused: self = .cameraRefused
        case .failed(let reason): self = .failed(reason)
        case .running:
            if paused {
                self = .paused
            } else if !faceFound {
                self = .noFace
            } else if let recentLowRate {
                self = .low(rate: rate, recent: recentLowRate)
            } else {
                self = .watching(rate: rate)
            }
        }
    }

    /// The camera is on and the pipeline is running (somebody in view or not).
    public var isCameraOn: Bool {
        switch self {
        case .noFace, .watching, .low: return true
        case .starting, .cameraRefused, .failed, .paused: return false
        }
    }

    /// The rate to display, when there is one.
    public var rate: Double? {
        switch self {
        case .watching(let rate), .low(let rate, _): return rate
        default: return nil
        }
    }
}
