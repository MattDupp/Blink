import Foundation

/// Your own usual blink rate, measured once.
public struct Reference: Equatable {
    /// Blinks a minute: the median of the minutes it was measured on.
    public let rate: Double
    public let measuredOn: Date
    /// How many minutes it was measured on.
    public let minutes: Int

    public init(rate: Double, measuredOn: Date, minutes: Int) {
        self.rate = rate
        self.measuredOn = measuredOn
        self.minutes = minutes
    }
}

/// A limit that fits YOU, without following you down.
///
/// People do not blink alike, so one limit for everybody ("under 10 a minute is too
/// little") is wrong for many. The natural fix is a personal baseline: learn your usual
/// rate and warn when you fall well under it.
///
/// THE TRAP (raised by this project's author when the feature was proposed): a baseline
/// that keeps averaging your recent weeks goes down with you. Blink a little less each
/// month and it follows; a limit set at 70% of it follows too, and the app never warns.
/// The measure would hide exactly the decline it exists to catch.
///
/// SO THE REFERENCE DOES NOT FOLLOW YOU:
///   - it is measured ONCE, when enough has been recorded, and then kept (`adopt`);
///   - nothing here recomputes it later - there is no function that could;
///   - a decline is REPORTED against it (`drift`) instead of being absorbed;
///   - measuring it again is a decision (`proposal`), and one that would lower it says so;
///   - the limit never goes under a floor you choose (`limit`), which covers a reference
///     measured while you were already blinking too little.
public enum Baseline {

    /// Calibration needs this much time watched...
    public static let calibrationSeconds = 3 * 3600.0
    /// ...spread over at least this many days: one unusual day is not "your usual rate".
    public static let calibrationDays = 2
    /// The automatic limit, as a share of the reference.
    public static let shareOfReference = 0.7
    /// A gap to the reference worth telling you about.
    public static let driftWorthSaying = 0.15
    /// A drift is only stated over at least this many minutes: an hour, not a moment.
    public static let driftMinutes = 60

    /// How far the recorded minutes are from being enough to measure a reference.
    public struct Calibration: Equatable {
        public let watchedSeconds: Double
        public let days: Int

        public init(watchedSeconds: Double, days: Int) {
            self.watchedSeconds = watchedSeconds
            self.days = days
        }

        /// 0...1: the smaller of "share of the time needed" and "share of the days needed".
        public var progress: Double {
            min(1, watchedSeconds / Baseline.calibrationSeconds, Double(days) / Double(Baseline.calibrationDays))
        }
        public var isComplete: Bool { progress >= 1 }
        /// Time at the screen still to record.
        public var secondsLeft: Double { max(0, Baseline.calibrationSeconds - watchedSeconds) }
        /// Days still to see: the measure needs minutes from two different days.
        public var daysLeft: Int { max(0, Baseline.calibrationDays - days) }
    }

    public static func calibration(records: [MinuteRecord], calendar: Calendar = .current) -> Calibration {
        let rated = records.filter { $0.ratePerMinute != nil }
        return Calibration(watchedSeconds: rated.reduce(0) { $0 + $1.observedSeconds },
                           days: Set(rated.map { calendar.startOfDay(for: $0.start) }).count)
    }

    /// The median rate of the minutes that have a rate. The median, not the average: a few
    /// minutes of laughing or of staring do not move it.
    public static func medianRate(of records: [MinuteRecord]) -> Double? {
        let rates = records.compactMap(\.ratePerMinute).sorted()
        guard !rates.isEmpty else { return nil }
        let middle = rates.count / 2
        return rates.count % 2 == 1 ? rates[middle] : (rates[middle - 1] + rates[middle]) / 2
    }

    /// The reference these minutes give, or nil while there is too little to measure one.
    public static func measure(records: [MinuteRecord], now: Date, calendar: Calendar = .current) -> Reference? {
        guard calibration(records: records, calendar: calendar).isComplete,
              let rate = medianRate(of: records) else { return nil }
        return Reference(rate: rate, measuredOn: now, minutes: records.filter { $0.ratePerMinute != nil }.count)
    }

    /// The reference to keep: the existing one when there is one - WHATEVER the minutes
    /// say now - else a first measurement, once calibration is complete.
    public static func adopt(existing: Reference?, records: [MinuteRecord], now: Date,
                             calendar: Calendar = .current) -> Reference? {
        existing ?? measure(records: records, now: now, calendar: calendar)
    }

    /// The limit in force, in blinks a minute: under it is "too little".
    /// `floor` is the limit you set by hand; the automatic limit can only be above it.
    public static func limit(reference: Reference?, automatic: Bool, floor: Int) -> Int {
        guard automatic, let reference else { return floor }
        return max(floor, Int((reference.rate * shareOfReference).rounded()))
    }

    /// The limit sits ABOVE your own usual rate, so the app would say "Low" most of the
    /// time. It happens when the floor, not your reference, sets the limit and you usually
    /// blink less than the floor. Blinking 5 to 10 times a minute at a screen is ordinary
    /// (`PublishedRates`), so this is a floor to lower, not a person to warn: the Settings
    /// window says so.
    public static func limitAboveUsual(reference: Reference?, limit: Int) -> Bool {
        guard let reference else { return false }
        return Double(limit) > reference.rate
    }

    /// The floor that makes the limit follow your own usual rate: the share of the
    /// reference that the automatic limit uses, and never under 1. It is what "Follow my
    /// own rate" sets when your usual rate was measured under the limit.
    public static func floorFollowing(reference: Reference) -> Int {
        max(1, Int((reference.rate * shareOfReference).rounded()))
    }

    /// How far the recent minutes are under the reference, as a share of it
    /// (0.22 = 22% less; negative = more than the reference). Nil when the recent minutes
    /// are too few to say.
    public static func drift(reference: Reference, recent: [MinuteRecord]) -> Double? {
        guard reference.rate > 0, recent.filter({ $0.ratePerMinute != nil }).count >= driftMinutes,
              let now = medianRate(of: recent) else { return nil }
        return (reference.rate - now) / reference.rate
    }

    /// What measuring again would change. It is put before the user; nothing adopts it.
    public struct Proposal: Equatable {
        public let current: Reference?
        public let measured: Reference

        /// The new reference is lower than the current one: adopting it lowers the bar.
        public var lowers: Bool {
            current.map { measured.rate < $0.rate } ?? false
        }
    }

    /// A new measurement to put before the user, or nil when there is too little to measure.
    public static func proposal(current: Reference?, records: [MinuteRecord], now: Date,
                                calendar: Calendar = .current) -> Proposal? {
        measure(records: records, now: now, calendar: calendar).map { Proposal(current: current, measured: $0) }
    }
}
