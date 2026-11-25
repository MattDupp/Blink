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

/// Where the eyes were in one frame: the height of the point half-way between them, and
/// the distance between them, in the frame's pixels (y from the top). Rule 5 of
/// `BlinkDetector` asks about it.
public struct EyeLevel: Equatable {
    public let height: Double
    public let apart: Double

    public init(height: Double, apart: Double) {
        self.height = height
        self.apart = apart
    }
}

/// STAGE 3 of the pipeline: turns the model's frame-by-frame answers into blinks.
///
/// The model only says, 30 times a second, "closed: 3%... 2%... 97%... 99%... 4%". A blink
/// is a PATTERN in that stream: open, then closed for a short moment, then open again.
/// This is a small state machine - plain logic, nothing learned - with five rules, each
/// there for a reason:
///
///  1. TWO THRESHOLDS, not one ("hysteresis"). The eyes count as closed above 60% and as
///     open again only below 40%. With a single line at 50%, an uncertain answer hovering
///     around it (49, 51, 48, 52) would count a blink at every crossing.
///  2. TWO FRAMES IN A ROW - OR ONE VERY SURE FRAME. The model is wrong on a small share
///     of frames; at 30 frames a second even 0.5% of lone mistakes would add 9 false
///     blinks a minute, so one isolated, hesitant "closed" frame is treated as a mistake.
///     But a fast blink can be closed on a single frame of a 30-frames-a-second camera.
///     MEASURED on 72 hand-marked blinks (2026-11-20, training/evaluate.py): asking for
///     two frames found 93% of them; also accepting one frame when the answer is at least
///     80% sure found all of them, with no additional false blink.
///  3. A MAXIMUM duration. A blink lasts 0.1 to 0.4 s. Eyes closed for longer are resting,
///     or looking down at the keyboard (which, seen from the camera, looks closed): that
///     is reported as a long closure, not counted as a blink.
///  4. NO GUESSING across gaps. If the face was lost while the eyes were closed, nobody
///     knows when they reopened: the closure is dropped.
///  5. A LID, NOT A HEAD. A closure during which the eyes moved up or down by more than
///     0.15 of the distance between them is not counted. Seen from a camera above the
///     screen, a head that goes down looks like closing eyes, and one that comes back up
///     like eyes that reopen: a nod, or a glance at the keyboard, shorter than rule 3's
///     0.6 s was counted as a blink. And while the head moves, squares found a frame
///     earlier no longer frame the eyes (`FrameSchedule`), so a lone frame can read "closed".
///     MEASURED 2026-11-25 (`BlinkReplay --squares`, data/replay, the model trained in
///     the app on 2026-11-22): during the 151 blinks marked by hand, the point between
///     the eyes moved up or down by 0.06 of their distance at the median and 0.10 at the
///     95th percentile (the lid coming down moves Vision's outline); during the closures
///     counted in two minutes of nodding, 0.16 to 1.18. With this rule, at the standard
///     effort, those two minutes went from 52 and 63 blinks to 20 and 21, and the 97
///     marked blinks found before were all still found. A real blink made while the head
///     moves up or down that much is lost: once in the older recordings, during a fast
///     head turn, on frames the marks do not cover.
public struct BlinkDetector {

    public struct Settings {
        public var closedAbove = 0.6
        public var openBelow = 0.4
        public var minimumClosedFrames = 2
        /// A closure seen on ONE frame only still counts when the answer was this sure.
        public var singleFrameSure = 0.8
        public var maximumBlinkSeconds = 0.6
        /// Longer than this without seeing the eyes = the thread is lost.
        public var maximumGapSeconds = 0.5
        /// How far the eyes may move up or down during a closure that is counted, in
        /// distances between the eyes (rule 5).
        public var maximumUpDown = 0.15
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
        /// `peak` is the surest answer seen during the closure.
        case closed(since: Double?, frames: Int, peak: Double)
    }

    public var settings: Settings
    public private(set) var state: State = .unknown
    private var lastSeen: Double?
    /// Where the eyes were on the last frame read (rule 5).
    private var lastLevel: EyeLevel?
    /// The lowest and the highest the eyes were from the frame before the lids came down,
    /// and how far apart they were then (rule 5). Nil while nothing said where they were.
    private var heights: (low: Double, high: Double, apart: Double)?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feed one frame. `closed` is the model's probability for this frame, or nil when
    /// no eye could be read (no face, eyes out of the picture). `eyes`: where they were,
    /// when it is known (rule 5 is not applied to frames that do not say).
    public mutating func update(time: Double, closed probability: Double?, eyes level: EyeLevel? = nil) -> Event? {
        if let lastSeen, time - lastSeen > settings.maximumGapSeconds {
            state = .unknown
        }
        guard let probability else { return nil }
        lastSeen = time
        let before = lastLevel
        lastLevel = level

        switch state {
        case .unknown:
            state = probability > settings.closedAbove ? .closed(since: nil, frames: 1, peak: probability) : .open
            return nil

        case .open:
            if probability > settings.closedAbove {
                state = .closed(since: time, frames: 1, peak: probability)
                heights = nil
                note(before)
                note(level)
            }
            return nil

        case .closed(let since, let frames, let peak):
            note(level)
            guard probability < settings.openBelow else {
                state = .closed(since: since, frames: frames + 1, peak: max(peak, probability))
                return nil
            }
            state = .open
            guard let since else { return nil }
            let duration = time - since
            if duration > settings.maximumBlinkSeconds {
                return .longClosure(seconds: duration)
            }
            let longEnough = frames >= settings.minimumClosedFrames || peak >= settings.singleFrameSure
            guard longEnough, upDown <= settings.maximumUpDown else { return nil }
            return .blink(Blink(start: since, end: time))
        }
    }

    /// How far the eyes moved up or down during the closure, in distances between the eyes.
    private var upDown: Double {
        guard let heights, heights.apart > 0 else { return 0 }
        return (heights.high - heights.low) / heights.apart
    }

    private mutating func note(_ level: EyeLevel?) {
        guard let level else { return }
        if let known = heights {
            heights = (min(known.low, level.height), max(known.high, level.height), known.apart)
        } else {
            heights = (level.height, level.height, level.apart)
        }
    }

    public mutating func reset() {
        state = .unknown
        lastSeen = nil
        lastLevel = nil
        heights = nil
    }
}
