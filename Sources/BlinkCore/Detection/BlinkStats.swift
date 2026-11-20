import Foundation

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
