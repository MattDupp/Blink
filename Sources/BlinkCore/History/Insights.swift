import Foundation

/// What the recorded minutes say about WHEN you blink too little.
public enum Insights {

    /// One rate per hour of the day (0...23) over all the given minutes; nil for an hour
    /// watched for less than `minimumSeconds` in total.
    public static func ratesByHour(records: [MinuteRecord], minimumSeconds: Double = 600,
                                   calendar: Calendar = .current) -> [Double?] {
        var watched = [Double](repeating: 0, count: 24)
        var blinks = [Int](repeating: 0, count: 24)
        for record in records {
            let hour = calendar.component(.hour, from: record.start)
            watched[hour] += record.observedSeconds
            blinks[hour] += record.blinks
        }
        return (0..<24).map { watched[$0] >= minimumSeconds ? Double(blinks[$0]) / watched[$0] * 60 : nil }
    }

    /// The hours of the day where the rate is lowest, lowest first.
    public static func lowestHours(records: [MinuteRecord], count: Int = 2,
                                   calendar: Calendar = .current) -> [(hour: Int, rate: Double)] {
        ratesByHour(records: records, calendar: calendar).enumerated()
            .compactMap { hour, rate in rate.map { (hour, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(count)
            .map { (hour: $0.0, rate: $0.1) }
    }

    /// The hours of the day worth drawing: from the first to the last hour with anything
    /// recorded, with an hour of margin on each side. The whole day when nothing is
    /// recorded. Most of a 24-hour axis was empty, and squeezed the hours that matter.
    public static func hoursUsed(records: [MinuteRecord], calendar: Calendar = .current) -> ClosedRange<Int> {
        let hours = records.filter { $0.observedSeconds >= 1 }.map { calendar.component(.hour, from: $0.start) }
        guard let first = hours.min(), let last = hours.max() else { return 0...23 }
        return max(0, first - 1)...min(23, last + 1)
    }

    /// Is this rate drawn as under the limit? Judged on the figure as it is WRITTEN, with
    /// one decimal: a bar labelled "10.0" was orange under a limit of 10.
    public static func isUnder(_ rate: Double, limit: Double) -> Bool {
        (rate * 10).rounded() / 10 < limit
    }

    /// The rate of every hour of every day: `[day][hour]`, nil where less than 10 minutes
    /// were watched. `days`: the starts of the days wanted, in the order wanted.
    public static func heatMap(records: [MinuteRecord], days: [Date], calendar: Calendar = .current) -> [[Double?]] {
        days.map { day in
            ratesByHour(records: records.on(day, calendar: calendar), calendar: calendar)
        }
    }
}
