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
    /// What that usually is, and what happens next.
    public static let silentWhy = "That is normal with the lid closed. Otherwise the camera restarts by itself."

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
