import Foundation

/// One detected blink.
public struct Blink: Equatable {
    /// Time of the first frame with the eyes closed, in seconds (the camera's clock).
    public let start: Double
    /// Time of the first frame with the eyes open again.
    public let end: Double
    public var duration: Double { end - start }

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// STAGE 3 of the pipeline: turns the model's frame-by-frame answers into blinks.
///
/// The model only says, 30 times a second, "closed: 3%... 2%... 97%... 99%... 4%". A blink
/// is a PATTERN in that stream: open, then closed for a short moment, then open again.
/// This is a small state machine - plain logic, nothing learned - with four rules, each
/// there for a reason:
///
///  1. TWO THRESHOLDS, not one ("hysteresis"). The eyes count as closed above 60% and as
///     open again only below 40%. With a single line at 50%, an uncertain answer hovering
///     around it (49, 51, 48, 52) would count a blink at every crossing.
///  2. A MINIMUM of two frames in a row. The model is wrong on a small share of frames;
///     at 30 frames a second even 0.5% of lone mistakes would add 9 false blinks a
///     minute. One isolated "closed" frame is treated as a mistake.
///  3. A MAXIMUM duration. A blink lasts 0.1 to 0.4 s. Eyes closed for longer are resting,
///     or looking down at the keyboard (which, seen from the camera, looks closed): that
///     is reported as a long closure, not counted as a blink.
///  4. NO GUESSING across gaps. If the face was lost while the eyes were closed, nobody
///     knows when they reopened: the closure is dropped.
public struct BlinkDetector {

    public struct Settings {
        public var closedAbove = 0.6
        public var openBelow = 0.4
        public var minimumClosedFrames = 2
        public var maximumBlinkSeconds = 0.6
        /// Longer than this without seeing the eyes = the thread is lost.
        public var maximumGapSeconds = 0.5
        public init() {}
    }

    public enum Event: Equatable {
        case blink(Blink)
        /// The eyes stayed closed too long to be a blink.
        case longClosure(seconds: Double)
    }

    public enum State: Equatable {
        /// Not seen yet, or lost for too long.
        case unknown
        case open
        /// `since` is nil when we did not see the eyes close (they were already closed
        /// when we first saw them): such a closure cannot be timed, so it is never a blink.
        case closed(since: Double?, frames: Int)
    }

    public var settings: Settings
    public private(set) var state: State = .unknown
    private var lastSeen: Double?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feed one frame. `closed` is the model's probability for this frame, or nil when
    /// no eye could be read (no face, eyes out of the picture).
    public mutating func update(time: Double, closed probability: Double?) -> Event? {
        if let lastSeen, time - lastSeen > settings.maximumGapSeconds {
            state = .unknown
        }
        guard let probability else { return nil }
        lastSeen = time

        switch state {
        case .unknown:
            state = probability > settings.closedAbove ? .closed(since: nil, frames: 1) : .open
            return nil

        case .open:
            if probability > settings.closedAbove {
                state = .closed(since: time, frames: 1)
            }
            return nil

        case .closed(let since, let frames):
            guard probability < settings.openBelow else {
                state = .closed(since: since, frames: frames + 1)
                return nil
            }
            state = .open
            guard let since else { return nil }
            let duration = time - since
            if duration > settings.maximumBlinkSeconds {
                return .longClosure(seconds: duration)
            }
            return frames >= settings.minimumClosedFrames ? .blink(Blink(start: since, end: time)) : nil
        }
    }

    public mutating func reset() {
        state = .unknown
        lastSeen = nil
    }
}
