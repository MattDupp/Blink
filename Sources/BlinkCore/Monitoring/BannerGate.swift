import Foundation

/// The one gate every banner asks before it shows.
///
/// The app has three kinds of reminder: the look-away break, the routines, and the blink
/// reminder. Each was built to be gentle on its own, and each knew nothing of the others:
/// a break banner, a routine banner and a blink banner could land in the same minute,
/// "look far away" could arrive in the middle of a blink break, and a routine could ask
/// for eye drops during a setup recording. So there is ONE place that says yes or no:
///
///   - nothing while you are busy with something the app itself started: a look-away
///     break, a blink break, a routine's timer, the setup;
///   - nothing during a call, when the user asked for that (`Busy.call`);
///   - at least two minutes between any two banners, whatever their kinds;
///   - when two would come together, a break goes first, then a routine, then the blink
///     reminder (the break is the one with a clock running; the blink reminder comes back
///     by itself);
///   - nothing at all while "Quiet" is on (`quiet(until:)`): no banner and no sound.
///     Counting goes on.
///
/// Like `BreakSchedule` and `RoutineDay`, it is handed the clock and the facts, and is
/// tested on timelines written by hand. It shows nothing itself.
public struct BannerGate: Equatable {

    /// The kinds of banner, in the order they go first.
    public enum Kind: Int, CaseIterable, Comparable {
        case screenBreak, routine, blink

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// What you are in the middle of, that a banner must not interrupt.
    public struct Busy: Equatable {
        public var lookAwayBreak = false
        public var blinkBreak = false
        public var timer = false
        public var setup = false
        /// A call is under way (the microphone is in use), and the user asked for quiet
        /// during calls: nothing interrupts it, a look-away break included.
        public var call = false

        public init(lookAwayBreak: Bool = false, blinkBreak: Bool = false, timer: Bool = false, setup: Bool = false,
                    call: Bool = false) {
            self.lookAwayBreak = lookAwayBreak
            self.blinkBreak = blinkBreak
            self.timer = timer
            self.setup = setup
            self.call = call
        }

        public static let free = Busy()

        /// Busy for a banner of this kind. A look-away break does not keep its own banner
        /// away: that banner is what announces it.
        public func holds(_ kind: Kind) -> Bool {
            blinkBreak || timer || setup || call || (lookAwayBreak && kind != .screenBreak)
        }
    }

    /// The least time between two banners of any kind.
    public static let gapSeconds = 120.0

    public private(set) var lastShown: Date?
    public private(set) var quietUntil: Date?

    public init(quietUntil: Date? = nil) {
        self.quietUntil = quietUntil
    }

    /// "Quiet" until `date` (nil: over now).
    public mutating func quiet(until date: Date?) {
        quietUntil = date
    }

    public func isQuiet(at now: Date) -> Bool {
        quietUntil.map { now < $0 } ?? false
    }

    /// May a banner of this kind show now? `soon`: the other kinds that have a banner to
    /// show at this moment or within the gap: one that goes first is waited for.
    public func mayShow(_ kind: Kind, busy: Busy = .free, soon: Set<Kind> = [], now: Date) -> Bool {
        if isQuiet(at: now) || busy.holds(kind) { return false }
        if let lastShown, now.timeIntervalSince(lastShown) < Self.gapSeconds, now >= lastShown { return false }
        return !soon.contains { $0 < kind }
    }

    /// A banner was shown: the gap starts.
    public mutating func shown(at now: Date) {
        lastShown = now
    }

    /// The ends "Quiet" offers, from `now`.
    public enum QuietLength: CaseIterable {
        case thirtyMinutes, oneHour, untilTomorrow

        public func end(from now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .thirtyMinutes: return now.addingTimeInterval(1800)
            case .oneHour: return now.addingTimeInterval(3600)
            case .untilTomorrow:
                return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
            }
        }
    }
}
