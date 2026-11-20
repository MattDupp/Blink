import Foundation

/// One candidate blink of a capture, as a person marked it in blinks.csv
/// (training/annotate.py lays the candidates out; a person fills in the kind).
public struct MarkedBlink: Equatable {

    public enum Kind: String {
        /// The lids came down far enough to hide the pupil, then reopened.
        case blink
        /// The lids came down part of the way only: neither required nor held against the count.
        case partial
        /// Not a blink: a glance down, a squint, a false alarm.
        case none
    }

    /// The app's frame numbers, as in trace.csv (or positions: see `BlinkScore`).
    public let firstFrame: Int
    public let lastFrame: Int
    public let kind: Kind

    public init(firstFrame: Int, lastFrame: Int, kind: Kind) {
        self.firstFrame = firstFrame
        self.lastFrame = lastFrame
        self.kind = kind
    }
}

/// How a count of blinks compares with what a person marked: the three numbers of
/// training/evaluate.py, computed the same way.
///
///     found    real blinks that were counted
///     missed   real blinks that were not
///     false    blinks counted where there was none, or a second count of the same blink
///
/// The rule is written twice (here and in `score` of evaluate.py); Python tests check that
/// the two windows are the same numbers and that one example gets one answer.
///
/// Frames are named by their POSITION among the frames where both eyes were read, as in
/// evaluate.py (`RecordedCapture.score` does the conversion from frame numbers).
public struct BlinkScore: Equatable, CustomStringConvertible {

    /// A blink is counted at the frame where the eyes reopen, just after its candidate;
    /// and a candidate's first frame can be a frame late. A count this close to a
    /// candidate is that candidate's.
    public static let framesBefore = 2
    public static let framesAfter = 5

    public var blinks = 0
    public var found = 0
    public var falseBlinks = 0
    /// Length of the video that was judged.
    public var seconds = 0.0

    public var missed: Int { blinks - found }

    public init() {}

    /// `counted`: the frames at which a blink was counted, named as the marks are.
    public init(counted: [Int], marks: [MarkedBlink], seconds: Double) {
        blinks = marks.filter { $0.kind == .blink }.count
        self.seconds = seconds
        var used = Set<Int>()
        for frame in counted {
            let match = marks.firstIndex {
                $0.firstFrame - Self.framesBefore <= frame && frame <= $0.lastFrame + Self.framesAfter
            }
            guard let match, marks[match].kind != .none, !used.contains(match) else {
                falseBlinks += 1
                continue
            }
            if marks[match].kind == .blink {
                used.insert(match)
                found += 1
            }
        }
    }

    public static func + (a: BlinkScore, b: BlinkScore) -> BlinkScore {
        var sum = BlinkScore()
        sum.blinks = a.blinks + b.blinks
        sum.found = a.found + b.found
        sum.falseBlinks = a.falseBlinks + b.falseBlinks
        sum.seconds = a.seconds + b.seconds
        return sum
    }

    /// The same sentence evaluate.py prints.
    public var description: String {
        let perMinute = seconds > 0 ? Double(falseBlinks) / seconds * 60 : 0
        return String(format: "%3d of %3d found (%5.1f%%)   %2d missed   %2d false (%.1f a minute)",
                      found, blinks, 100 * Double(found) / Double(max(blinks, 1)), missed, falseBlinks, perMinute)
    }
}
