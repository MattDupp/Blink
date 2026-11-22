import Foundation

/// The count behind "every 60 minutes at the screen".
///
/// WHAT IS COUNTED. Time with somebody at the screen, not time on the clock. An hour of
/// work, lunch, then twenty minutes of work is eighty minutes on the count's side, not
/// the two hours and more the clock saw.
///
/// It is a small state machine with no clock and no camera of its own. Somebody else
/// looks every few seconds and tells it two things: what time it is, and whether
/// somebody is there (`advance`). That keeps the rules testable on a timeline written
/// by hand.
///
/// The rules:
///   - while somebody is there, the time since the last look is added;
///   - when the count reaches the routine's minutes, an OCCASION opens (the reminder is
///     due) and the count starts again from zero at once. So the next one is that many
///     minutes of screen later, whatever you answer, and two can never be open together:
///     a new occasion replaces an old one left unanswered;
///   - "Done" starts the count again (`restart`). "Later" does not touch it;
///   - FIVE MINUTES AWAY IN A ROW start the count again, and close an occasion left open.
///     You got up: when you come back, an hour at the screen starts again, and a
///     reminder from before your break is not waiting for you. A shorter absence (you
///     turn to the phone, the camera loses your face) only stops the count;
///   - a look that comes long after the last one (the Mac slept, the app was stuck) is
///     time away, not time at the screen;
///   - while `holding` (a routine's timer runs, eyes covered), the count stands still:
///     neither at the screen nor away;
///   - a new day starts at zero, with nothing open.
///
/// The count lives in memory only. After a relaunch it starts from zero: the reminder
/// comes later that once, never twice.
public struct ScreenCount: Equatable {

    /// One time the count was reached: a reminder that is due.
    public struct Occasion: Equatable {
        /// Its name in the record: the day on the wall clock and its number that day,
        /// "2026-11-21#3".
        public let key: String
        public let due: Date
    }

    /// Away this long in a row: the count starts again.
    public static let awaySeconds = 300.0
    /// Two looks further apart than this were not a normal tick: the time between them
    /// is taken as time away.
    public static let longestStep = 90.0

    /// Seconds at the screen since the count last started.
    public private(set) var seconds = 0.0
    /// Seconds away in a row.
    public private(set) var away = 0.0
    /// The latest occasion of today, answered or not. `RoutineDay` reads its state from the record.
    public private(set) var open: Occasion?

    private var day = ""
    private var rounds = 0
    private var last: Date?

    public init() {}

    /// Whole minutes still to go before the next occasion, for a routine of `minutes`.
    public func minutesLeft(of minutes: Int) -> Int {
        max(Int(((Double(minutes) * 60 - seconds) / 60).rounded(.up)), 0)
    }

    /// One look at the world, at `now`: was somebody at the screen since the last look?
    public mutating func advance(to now: Date, present: Bool, holding: Bool = false, minutes: Int,
                                 calendar: Calendar = .current) {
        let today = RoutineWeek.key(of: now, calendar: calendar)
        if today != day {
            self = ScreenCount()
            day = today
        }
        let step = last.map { now.timeIntervalSince($0) } ?? 0
        last = now
        guard step > 0, !holding else { return }

        if present && step <= Self.longestStep {
            seconds += step
            away = 0
        } else {
            away += step
            if away >= Self.awaySeconds {
                seconds = 0
                open = nil
            }
        }
        if seconds >= Double(max(minutes, 1)) * 60 {
            rounds += 1
            open = Occasion(key: "\(day)#\(rounds)", due: now)
            seconds = 0
        }
    }

    /// "Done": the count starts again from here.
    public mutating func restart() {
        seconds = 0
        away = 0
    }
}
