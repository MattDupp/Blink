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

/// Counts blinks against the time the eyes were really watched.
///
/// "12 blinks in the last minute" means nothing if you were away from the screen for half
/// of it. So the rate is blinks per minute OF OBSERVED TIME: only the time during which
/// the eyes were being read counts.
public struct BlinkStats {

    public private(set) var totalBlinks = 0
    public private(set) var longClosures = 0
    public private(set) var observedSeconds = 0.0
    public private(set) var lastBlink: Blink?

    /// How much history is kept for the rolling rate.
    public static let historySeconds = 600.0

    private var blinkTimes: [Double] = []
    private var watched: [(time: Double, seconds: Double)] = []
    private var lastFrame: Double?

    public init() {}

    /// Call for every frame; `eyesRead` says whether the model could judge this frame.
    /// Returns the watched time this frame added, in seconds (0 when it added none).
    @discardableResult
    public mutating func frame(time: Double, eyesRead: Bool) -> Double {
        defer { lastFrame = eyesRead ? time : nil }
        guard eyesRead, let lastFrame else { return 0 }
        let step = time - lastFrame
        // A step longer than half a second is a hole in the video, not watched time.
        guard step > 0, step <= 0.5 else { return 0 }
        observedSeconds += step
        watched.append((time, step))
        trim(now: time)
        return step
    }

    public mutating func record(_ event: BlinkDetector.Event) {
        switch event {
        case .blink(let blink):
            totalBlinks += 1
            lastBlink = blink
            blinkTimes.append(blink.end)
        case .longClosure:
            longClosures += 1
        }
    }

    public func blinks(inLast seconds: Double, now: Double) -> Int {
        blinkTimes.filter { $0 > now - seconds }.count
    }

    public func observed(inLast seconds: Double, now: Double) -> Double {
        watched.reduce(0) { $1.time > now - seconds ? $0 + $1.seconds : $0 }
    }

    /// Blinks per minute of observed time over the last `seconds`. Nil until at least
    /// 20 s of it were observed: a rate computed on a few seconds jumps around wildly.
    public func ratePerMinute(inLast seconds: Double, now: Double) -> Double? {
        let time = observed(inLast: seconds, now: now)
        guard time >= 20 else { return nil }
        return Double(blinks(inLast: seconds, now: now)) / time * 60
    }

    private mutating func trim(now: Double) {
        let limit = now - Self.historySeconds
        if let first = watched.first, first.time < limit - 60 {
            watched.removeAll { $0.time < limit }
            blinkTimes.removeAll { $0 < limit }
        }
    }
}
