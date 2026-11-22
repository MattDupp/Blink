import BlinkCore

/// What a camera view says while it has no picture to show: worded once, for every window.
public enum CameraNote {

    public static func text(for lifecycle: Lifecycle, appName: String) -> String {
        switch lifecycle {
        case .cameraRefused:
            return "Camera access was refused.\nAllow \(appName) in System Settings > Privacy & Security > Camera."
        case .failed(let reason):
            return reason
        case .needsSetup:
            return "The camera is off: \(appName) has not learned your eyes yet."
        case .starting, .running:
            return "Starting the camera…"
        }
    }
}
