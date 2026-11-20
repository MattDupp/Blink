import Foundation

/// A blink break: a short exercise of slow, complete blinks, counted as you do them.
///
/// WHY ITS OWN COUNTING RULE. The monitor counts a closure of up to 0.6 s as a blink and
/// reports a longer one as "eyes closed for a while". But the blinks of this exercise are
/// slow on purpose - close gently, hold a moment, open - and usually last longer than
/// that. Here every completed closure counts, up to 3 s; the monitor's own counting is
/// not changed by it.
public struct BlinkBreak: Equatable {

    /// A closure longer than this is resting, not an exercise blink.
    public static let longestClosure = 3.0

    public let target: Int
    public private(set) var count = 0

    public init(target: Int = 10) {
        self.target = max(1, target)
    }

    public var isDone: Bool { count >= target }

    /// 0...1, for the ring.
    public var progress: Double { Double(min(count, target)) / Double(target) }

    /// Feed every event of the blink detector while the exercise runs.
    public mutating func record(_ event: BlinkDetector.Event) {
        guard !isDone else { return }
        switch event {
        case .blink:
            count += 1
        case .longClosure(let seconds):
            if seconds <= Self.longestClosure { count += 1 }
        }
    }
}
