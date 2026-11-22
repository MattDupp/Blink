import Foundation

/// The day in a few numbers: what the optional summary banner says.
///
/// It is worked out from the minutes on file and the clock, never stored. A day with too
/// little time at the screen gives no rate: twenty minutes of blinks say nothing about a
/// day, and the banner says "too little" instead of a number that looks like a result.
/// A day with no time at the screen at all gives no banner.
public struct DayDigest: Equatable {

    /// Under this much time at the screen, no rate is given.
    public static let minimumSeconds = 30.0 * 60
    /// The same for the line about last week.
    public static let minimumWeekSeconds = 2.0 * 3600

    public enum Day: Equatable {
        /// Nothing was counted today: nothing is said.
        case notAtScreen
        case tooLittle(seconds: Double)
        /// `aboveLimit`: the share of the rated minutes at or above the limit, in percent.
        case counted(seconds: Double, rate: Double, aboveLimit: Int?)
    }

    public struct Week: Equatable {
        public let seconds: Double
        public let rate: Double

        public init(seconds: Double, rate: Double) {
            self.seconds = seconds
            self.rate = rate
        }
    }

    public let day: Day
    /// Look-away breaks taken today.
    public let breaksTaken: Int
    /// On a Monday: the seven days that ended yesterday, when enough was counted in them.
    public let lastWeek: Week?

    public init(day: Day, breaksTaken: Int = 0, lastWeek: Week? = nil) {
        self.day = day
        self.breaksTaken = breaksTaken
        self.lastWeek = lastWeek
    }

    public init(records: [MinuteRecord], limit: Double, breaksTaken: Int, now: Date, calendar: Calendar) {
        let today = DaySummary(records: records.on(now, calendar: calendar).filter { $0.start <= now }, threshold: limit)
        if today.observedSeconds < 1 {
            day = .notAtScreen
        } else if today.observedSeconds < Self.minimumSeconds {
            day = .tooLittle(seconds: today.observedSeconds)
        } else {
            let rate = Double(today.blinks) / today.observedSeconds * 60
            day = .counted(seconds: today.observedSeconds, rate: rate,
                           aboveLimit: today.lowShare.map { Int(((1 - $0) * 100).rounded()) })
        }
        self.breaksTaken = breaksTaken

        // Monday, whatever day this Mac's week starts on: the working week begins.
        if calendar.component(.weekday, from: now) == 2 {
            let start = calendar.startOfDay(for: now)
            let week = HistoryWeeks.week(0, now: start.addingTimeInterval(-3600), calendar: calendar)     // ends yesterday
            let summary = DaySummary(records: week.records(in: records), threshold: limit)
            lastWeek = summary.observedSeconds >= Self.minimumWeekSeconds
                ? Week(seconds: summary.observedSeconds, rate: Double(summary.blinks) / summary.observedSeconds * 60) : nil
        } else {
            lastWeek = nil
        }
    }
}

/// When the summary banner is due: once a day, from the chosen hour on, on that day only.
///
/// Handed the clock, like every rule about time here. A Mac asleep at the hour shows the
/// summary when it is back, the same day. The next morning it shows nothing of yesterday:
/// a summary of a day that is over would arrive as the first banner of a new one.
public enum SummarySchedule {

    /// The day a summary was shown on, as it is remembered: "2026-11-20".
    public static func key(of date: Date, calendar: Calendar) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    public static func isDue(now: Date, hour: Int, lastShown: String?, calendar: Calendar) -> Bool {
        calendar.component(.hour, from: now) >= hour && lastShown != key(of: now, calendar: calendar)
    }
}
