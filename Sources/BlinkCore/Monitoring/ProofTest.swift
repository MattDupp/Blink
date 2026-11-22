import Foundation

/// The test at the end of setup: ten ticks, and you blink once at each.
///
/// WHY A TEST OF BLINKS, when the training already says how many pictures it got right.
/// The first model of this project answered 99.6% of pictures right and then missed about
/// one fast blink in two in real use (docs/LESSONS.md, lessons 2 and 4): a blink is a
/// handful of frames with the lid moving, and no picture of an eye held still shows that.
/// The only honest check is the thing the app is for: blinks, counted. Ten of them at
/// known moments take fifteen seconds.
///
/// This type only keeps the times and scores them; the window plays the ticks.
public struct ProofTest: Equatable {

    public static let ticks = 10
    public static let secondsBetweenTicks = 1.5
    /// The calm before the first tick. The click on "Start the Test" leaves a hand on the
    /// trackpad and eyes on the button: at 0.8 s the first tick was often missed, and one
    /// miss is half of what the test allows. The window says "Get ready" meanwhile.
    public static let secondsBeforeFirstTick = 2.0
    /// Blinks to find for the model to be trusted. The app's own bar, during development,
    /// was every marked blink found with at most one false one: 8 of 10 leaves room for a
    /// tick you missed yourself.
    public static let passMark = 8
    /// A blink may start this long BEFORE its tick: ticks are regular, and people go with
    /// the rhythm.
    static let lead = 0.3

    public struct Result: Equatable {
        /// Ticks that were answered by a counted blink.
        public var found: Int
        public var of: Int
        /// Blinks counted that no tick asked for (a second one after a tick).
        public var extra: Int

        public var passed: Bool { found >= ProofTest.passMark }

        public init(found: Int, of: Int, extra: Int) {
            self.found = found
            self.of = of
            self.extra = extra
        }
    }

    /// The camera-clock time of each tick played so far, and of each blink counted.
    public private(set) var tickTimes: [Double] = []
    public private(set) var blinkStarts: [Double] = []

    public init() {}

    public mutating func tick(at time: Double) {
        tickTimes.append(time)
    }

    public mutating func blink(_ blink: Blink) {
        blinkStarts.append(blink.start)
    }

    public var isComplete: Bool { tickTimes.count >= Self.ticks }

    /// Which ticks have been answered so far: one entry per tick played.
    public var answered: [Bool] {
        var answered = [Bool](repeating: false, count: tickTimes.count)
        for start in blinkStarts {
            if let tick = tick(of: start), !answered[tick] { answered[tick] = true }
        }
        return answered
    }

    /// The tick a blink that started at `start` answers: the last one played before it
    /// (give or take the lead). Nil for a blink before the first tick, or long after the last.
    private func tick(of start: Double) -> Int? {
        guard let index = tickTimes.lastIndex(where: { $0 - Self.lead <= start }) else { return nil }
        return start < tickTimes[index] - Self.lead + Self.secondsBetweenTicks ? index : nil
    }

    public var result: Result {
        let found = answered.filter { $0 }.count
        let duringTheTest = blinkStarts.filter { tick(of: $0) != nil }.count
        return Result(found: found, of: Self.ticks, extra: duringTheTest - found)
    }
}
