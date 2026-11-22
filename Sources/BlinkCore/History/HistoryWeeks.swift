import Foundation

/// Seven days of the history, as the History window pages through them.
///
/// The window always showed "the last 7 days": today and the six days before it. Going
/// back keeps that shape: week 0 is those seven days, week 1 the seven days before them,
/// and so on. A week here is seven whole days that END on a known day, not Monday to
/// Sunday: on a Monday morning a calendar week would show one bar and hide last week.
///
/// The days are counted by the calendar, never as 7 x 86,400 seconds: a week that holds
/// the night the clocks change has a day of 23 or 25 hours, and its days must still start
/// at midnight. Like every rule about time here, it is handed the moment and the
/// calendar, and tested on dates written by hand.
public struct HistoryWeek: Equatable {

    /// 0: the seven days ending today. 1: the seven before. And so on.
    public let index: Int
    /// The starts of its seven days, oldest first.
    public let days: [Date]
    /// The start of the day after its last one: a minute belongs to the week when it
    /// starts before this.
    public let end: Date

    public var start: Date { days.first ?? end }
    /// The last day of the week (its start).
    public var lastDay: Date { days.last ?? end }

    /// Week 0 holds today, which is not over: its numbers still move.
    public var isInProgress: Bool { index == 0 }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// The minutes of this week.
    public func records(in all: [MinuteRecord]) -> [MinuteRecord] {
        all.filter { contains($0.start) }
    }
}

public enum HistoryWeeks {

    /// How many weeks the window can go back, and draws in its row of weeks.
    public static let shown = 12

    /// The week `index` weeks back from the one that ends today.
    public static func week(_ index: Int, now: Date, calendar: Calendar) -> HistoryWeek {
        let today = calendar.startOfDay(for: now)
        func day(_ back: Int) -> Date {
            calendar.date(byAdding: .day, value: -back, to: today).map { calendar.startOfDay(for: $0) }
                ?? today.addingTimeInterval(-Double(back) * 86_400)
        }
        let last = max(index, 0) * 7
        return HistoryWeek(index: max(index, 0), days: (0..<7).reversed().map { day(last + $0) }, end: day(last - 1))
    }

    /// The last `count` weeks, oldest first: the order they are drawn in.
    public static func weeks(_ count: Int = shown, now: Date, calendar: Calendar) -> [HistoryWeek] {
        (0..<count).reversed().map { week($0, now: now, calendar: calendar) }
    }

    /// One summary per week, in the order given.
    public static func summaries(of weeks: [HistoryWeek], records: [MinuteRecord], threshold: Double) -> [DaySummary] {
        weeks.map { DaySummary(records: $0.records(in: records), threshold: threshold) }
    }

    /// Is anything recorded before this week, within the weeks that can be shown? The
    /// arrow to the earlier week leads somewhere only then.
    public static func hasEarlier(than week: HistoryWeek, records: [MinuteRecord], now: Date, calendar: Calendar) -> Bool {
        guard week.index < shown - 1 else { return false }
        let oldest = self.week(shown - 1, now: now, calendar: calendar).start
        return records.contains { $0.start >= oldest && $0.start < week.start && $0.observedSeconds >= 1 }
    }
}
