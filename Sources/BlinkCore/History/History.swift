import Foundation

/// What happened during one minute of the clock.
public struct MinuteRecord: Equatable {
    /// The start of the minute (seconds = 0).
    public let start: Date
    /// How long, within that minute, the eyes were really being read.
    public var observedSeconds: Double
    public var blinks: Int

    public init(start: Date, observedSeconds: Double, blinks: Int) {
        self.start = start
        self.observedSeconds = observedSeconds
        self.blinks = blinks
    }

    /// Blinks per minute of watched time. Nil when less than 20 s were watched: a rate
    /// from a few seconds says nothing.
    public var ratePerMinute: Double? {
        observedSeconds >= 20 ? Double(blinks) / observedSeconds * 60 : nil
    }

    public static func minuteStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}

public extension Array where Element == MinuteRecord {

    /// The records of one calendar day.
    ///
    /// Two date comparisons per record, against the day's two ends. The obvious way -
    /// asking the calendar "is this the same day?" for each record - cost 4 ms on a week
    /// of minutes, and the panel asks at every redraw: measured, it was nearly half of
    /// the main thread's work with the Live View open.
    func on(_ day: Date, calendar: Calendar = .current) -> [MinuteRecord] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return filter { $0.start >= start && $0.start < end }
    }
}

/// Sorts the stream of frames into minutes of the clock.
///
/// The live counters forget everything after ten minutes. To answer "do I blink enough?"
/// over a day, the app keeps one small record per minute: time watched and blinks.
/// Minutes, because the answer changes with what you do - reading, a video call, a break -
/// and a single figure for the day would hide exactly that.
public struct MinuteAggregator {

    /// The minute being filled.
    public private(set) var current: MinuteRecord?

    public init() {}

    /// Feed one frame. Returns the minute that just ended, when this frame starts a new one.
    public mutating func add(at date: Date, observedSeconds: Double, blinks: Int) -> MinuteRecord? {
        let start = MinuteRecord.minuteStart(of: date)
        var finished: MinuteRecord?
        if let current, current.start != start {
            finished = current
            self.current = nil
        }
        var record = current ?? MinuteRecord(start: start, observedSeconds: 0, blinks: 0)
        record.observedSeconds += observedSeconds
        record.blinks += blinks
        current = record
        return finished
    }
}

/// A stretch of minutes at a glance: a day, or an hour of the day.
public struct DaySummary: Equatable {
    public var observedSeconds = 0.0
    public var blinks = 0
    /// Minutes with a usable rate, and how many of them were under the threshold.
    public var ratedMinutes = 0
    public var lowMinutes = 0

    public var ratePerMinute: Double? {
        observedSeconds >= 60 ? Double(blinks) / observedSeconds * 60 : nil
    }

    /// Share of the rated minutes that were under the threshold, 0...1.
    public var lowShare: Double? {
        ratedMinutes > 0 ? Double(lowMinutes) / Double(ratedMinutes) : nil
    }

    public init(records: [MinuteRecord], threshold: Double) {
        for record in records {
            observedSeconds += record.observedSeconds
            blinks += record.blinks
            if let rate = record.ratePerMinute {
                ratedMinutes += 1
                if rate < threshold { lowMinutes += 1 }
            }
        }
    }
}

/// The minutes on disk: one line each, in a plain text file that any spreadsheet opens.
///
///     ~/Library/Application Support/BlinkMonitor/history.csv
///     start,observed_seconds,blinks
///     2026-11-20T10:15:00Z,58.4,11
///
/// Only numbers are kept. No picture ever leaves the camera pipeline. The Python side
/// reads this file too: its format does not change.
public typealias HistoryStore = RecordFile<MinuteRecord>

extension MinuteRecord: RecordLine {
    public static let fileName = "history.csv"
    public static let header = "start,observed_seconds,blinks"
    public var at: Date { start }

    public var fields: [String] {
        [RecordDates.string(start), String(format: "%.1f", observedSeconds), String(blinks)]
    }

    public init?(fields: [String]) {
        guard fields.count == 3, let start = RecordDates.date(fields[0]),
              let observed = Double(fields[1]), let blinks = Int(fields[2]) else { return nil }
        self.init(start: start, observedSeconds: observed, blinks: blinks)
    }
}
