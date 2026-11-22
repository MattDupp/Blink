import BlinkCore

/// What a camera view says while it has no picture to show: worded once, for every window.
public enum CameraNote {

    // ONE SENTENCE PER STATE OF THE CAMERA, used by every window that has to say it. The
    // same state was worded three ways in three places ("refused", "not allowed"; three
    // endings after "not sending pictures").

    /// The camera is blocked for this app in System Settings.
    public static func blocked(appName: String) -> String { "\(appName) is not allowed to use the camera." }
    /// What to do about it.
    public static func unblock(appName: String) -> String {
        "Turn \(appName) on in System Settings > Privacy & Security > Camera."
    }
    /// The camera is on and sends nothing.
    public static let silent = "The camera is not sending pictures."
    /// What that usually is, and what happens next. Worded by where the camera is: the
    /// sentence spoke of a lid on Macs that have none.
    public static func silentWhy(_ place: CameraPlace) -> String {
        switch place {
        case .lid: return "That is normal with the lid closed. Otherwise the camera restarts by itself."
        case .screen: return "The camera restarts by itself."
        case .separate: return "Check that it is plugged in. Otherwise the camera restarts by itself."
        }
    }

    /// The setup's camera page, when the camera sends nothing.
    public static func silentAdvice(_ place: CameraPlace) -> String {
        switch place {
        case .lid: return "That is normal with the lid closed. Open it, or choose another camera: the camera in use has to face you."
        case .screen: return "Wait a moment, or choose another camera: the camera in use has to face you."
        case .separate: return "Check that it is plugged in, or choose another camera: the camera in use has to face you."
        }
    }

    /// The setup's camera page, when no face is found.
    public static func faceIt(_ place: CameraPlace) -> String {
        switch place {
        case .lid: return "The Mac's own camera has to face you: the lid open, you in front of it."
        case .screen: return "The Mac's own camera has to face you: sit in front of the screen."
        case .separate: return "The camera has to face you: turn it towards you, or sit in front of it."
        }
    }

    /// No camera at all: what to try.
    public static func findOne(macHasLid: Bool) -> String {
        macHasLid ? "Plug one in, or open the lid" : "Plug one in"
    }

    public static func text(for lifecycle: Lifecycle, appName: String) -> String {
        switch lifecycle {
        case .cameraRefused:
            return blocked(appName: appName) + "\n" + unblock(appName: appName)
        case .failed(let reason):
            return reason
        case .needsSetup:
            return "The camera is off: \(appName) has not learned your eyes yet."
        case .starting, .running:
            return "Starting the camera…"
        }
    }
}
