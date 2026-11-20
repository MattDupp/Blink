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

    /// The rate of every hour of every day: `[day][hour]`, nil where less than 10 minutes
    /// were watched. `days`: the starts of the days wanted, in the order wanted.
    public static func heatMap(records: [MinuteRecord], days: [Date], calendar: Calendar = .current) -> [[Double?]] {
        days.map { day in
            ratesByHour(records: records.filter { calendar.isDate($0.start, inSameDayAs: day) }, calendar: calendar)
        }
    }
}
