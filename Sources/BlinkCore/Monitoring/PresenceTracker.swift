import Foundation

/// How long you have been at the screen without a break.
///
/// The camera pipeline knows, frame by frame, whether a face is in view. A BREAK is a
/// stretch with no face (20 s by default): you got up, or turned away. This counts the
/// time since the last break, which is what a "look away for a moment" nudge needs.
///
/// What it cannot know: where you look. Staring out of the window with your face still
/// in view is not seen as a break, so a nudge also restarts the count (`restart`).
public struct PresenceTracker {

    /// No face for this long counts as a break.
    public var breakSeconds = 20.0

    private var presentSince: Double?
    private var lastSeen: Double?

    public init() {}

    /// Feed every frame; `time` is the camera's clock, in seconds.
    public mutating func frame(time: Double, faceFound: Bool) {
        guard faceFound else { return }
        // First sight, back from a break, or a clock that started again: a new stretch.
        let sameStretch = lastSeen.map { time >= $0 && time - $0 < breakSeconds } ?? false
        if !sameStretch { presentSince = time }
        lastSeen = time
    }

    /// Seconds at the screen since the last break (0 during a break).
    public func continuousSeconds(at time: Double) -> Double {
        guard let presentSince, let lastSeen, time >= lastSeen, time - lastSeen < breakSeconds else { return 0 }
        return lastSeen - presentSince
    }

    /// Start counting again from now (a nudge was just shown).
    public mutating func restart(at time: Double) {
        presentSince = time
        lastSeen = time
    }
}
