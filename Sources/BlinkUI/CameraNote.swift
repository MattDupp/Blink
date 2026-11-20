import BlinkCore

/// What a camera view says while it has no picture to show. Both apps word it the same way.
public enum CameraNote {

    public static func text(for lifecycle: Lifecycle, appName: String) -> String {
        switch lifecycle {
        case .cameraRefused:
            return "Camera access was refused.\nSystem Settings > Privacy & Security > Camera > allow \(appName), then open it again."
        case .failed(let reason):
            return reason
        case .starting, .running:
            return "Starting the camera..."
        }
    }
}
