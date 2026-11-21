import BlinkCore

/// What a camera view says while it has no picture to show: worded once, for every window.
public enum CameraNote {

    public static func text(for lifecycle: Lifecycle, appName: String) -> String {
        switch lifecycle {
        case .cameraRefused:
            return "Camera access was refused.\nSystem Settings > Privacy & Security > Camera > allow \(appName), then open it again."
        case .failed(let reason):
            return reason
        case .needsSetup:
            return "The camera is off: \(appName) has no model of your eyes yet."
        case .starting, .running:
            return "Starting the camera..."
        }
    }
}
