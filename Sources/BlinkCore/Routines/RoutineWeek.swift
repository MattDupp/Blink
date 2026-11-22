import Foundation

/// A week of a routine that is counted by the week: "three times a week".
///
/// WHAT "THREE TIMES A WEEK" MEANS HERE. A count to reach, not three appointments. The
/// routine has days it prefers (Monday, Wednesday, Friday) and one time of day. The rule
/// that decides whether a day asks is short:
///
///   - nothing asks once the count is reached;
///   - a preferred day asks;
///   - another day asks when you are BEHIND: the preferred days still to come are fewer
///     than the times still to do. Miss Wednesday, and Thursday asks.
///
/// "Behind" is judged from what was done BEFORE that day, so a day's answer does not
/// change as the day goes on, and yesterday can be judged again today and give the same
/// answer. A day asks once at most, and never again after something was done that day.
///
/// What follows from the rule, with no extra code:
///   - done early (on a day that did not ask, or before the time) counts like any other;
///   - two on one day count as two;
///   - late in the week, when the count is out of reach, each day left asks once and no
///     more. Nothing is carried into the next week: a new week starts at zero;
///   - the first week, when the routine was switched on part of the way through, asks on
///     preferred days only. Catching up on a week you did not start would be nagging.
///
/// Like `RoutineDay`, this is a pure function of the routine, the record, the clock and
/// the calendar. The week starts where the calendar says it does (Monday or Sunday, as
/// the Mac is set). A "done" is kept under the date on the wall clock (see `key(of:)`),
/// so that a change of time zone does not move it to another day.
public struct RoutineWeek: Equatable {

    public struct Day: Equatable, Identifiable {
        /// The day on the wall clock, "2026-11-20": the name of this day in the record.
        public let key: String
        /// Its first moment, on this Mac's clock as it is set now.
        public let start: Date
        /// 1 = Sunday ... 7 = Saturday.
        public let weekday: Int
        /// How many times it was done that day.
        public let done: Int
        public let isPreferred: Bool
        /// The routine asks on this day (for a day to come: if nothing more is done before it).
        public let asks: Bool

        public var id: String { key }
    }

    /// How many times a week.
    public let target: Int
    /// The days of the week, in order. Seven, except in the rare weeks a calendar cuts short.
    public let days: [Day]
    /// Which of `days` is the day the week was asked about.
    public let todayIndex: Int

    public var done: Int { days.reduce(0) { $0 + $1.done } }
    public var isReached: Bool { done >= target }
    public var today: Day { days[todayIndex] }

    /// The next day after today that asks, this week. Nil: nothing more this week.
    public var nextAsk: Day? {
        days.dropFirst(todayIndex + 1).first { $0.asks }
    }

    /// The week that holds `day`. Nil when the routine is not counted by the week.
    public init?(routine: Routine, record: [RoutineEvent], on day: Date, calendar: Calendar = .current) {
        guard case .timesPerWeek(let count, let weekdays, _) = routine.schedule,
              let span = calendar.dateInterval(of: .weekOfYear, for: day) else { return nil }
        let today = calendar.startOfDay(for: day)

        var starts: [Date] = []
        var start = calendar.startOfDay(for: span.start)
        while start < span.end, starts.count < 7 {
            starts.append(start)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { break }
            start = next
        }
        guard let todayIndex = starts.firstIndex(of: today) else { return nil }

        // What was done each day: every `done` under that day's key, less the ones taken back.
        let mine = record.filter { $0.routine == routine.id }
        let keys = starts.map { Self.key(of: $0, calendar: calendar) }
        let doneEachDay = keys.map { key in
            RoutineDay.standing(mine.filter { $0.slot == key }).filter { $0.action == .done }.count
        }
        let preferred = starts.map { weekdays.contains(calendar.component(.weekday, from: $0)) }
        // Switched on during this week: no catching up, and nothing before that day.
        let firstWeek = routine.onSince.map { $0 >= span.start } ?? false
        let onDay = routine.onSince.map { calendar.startOfDay(for: $0) }

        var doneBefore = 0
        var built: [Day] = []
        for index in starts.indices {
            let remaining = max(count, 1) - doneBefore
            let preferredAfter = preferred[(index + 1)...].filter { $0 }.count
            let behind = !firstWeek && remaining > preferredAfter
            let beforeOn = onDay.map { starts[index] < $0 } ?? false
            built.append(Day(key: keys[index], start: starts[index],
                             weekday: calendar.component(.weekday, from: starts[index]),
                             done: doneEachDay[index], isPreferred: preferred[index],
                             asks: remaining > 0 && !beforeOn && (preferred[index] || behind)))
            doneBefore += doneEachDay[index]
        }
        target = max(count, 1)
        days = built
        self.todayIndex = todayIndex
    }

    /// The day of `date` on the wall clock, "2026-11-20", with no time zone.
    ///
    /// Why not the moment? For the same reason as `RoutineSlot.key`: done on Friday
    /// evening in Paris must still be "done on Friday" after a flight, not move to another
    /// day because the same moment is called something else in New York.
    public static func key(of date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}
