import Foundation

/// What happened during one minute of the clock.
struct MinuteRecord: Equatable {
    /// The start of the minute (seconds = 0).
    let start: Date
    /// How long, within that minute, the eyes were really being read.
    var observedSeconds: Double
    var blinks: Int

    /// Blinks per minute of watched time. Nil when less than 20 s were watched: a rate
    /// from a few seconds says nothing.
    var ratePerMinute: Double? {
        observedSeconds >= 20 ? Double(blinks) / observedSeconds * 60 : nil
    }

    static func minuteStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}

/// Sorts the stream of frames into minutes of the clock.
///
/// The live counters forget everything after ten minutes. To answer "do I blink enough?"
/// over a day, the app keeps one small record per minute: time watched and blinks.
/// Minutes, because the answer changes with what you do - reading, a video call, a break -
/// and a single figure for the day would hide exactly that.
struct MinuteAggregator {

    /// The minute being filled.
    private(set) var current: MinuteRecord?

    /// Feed one frame. Returns the minute that just ended, when this frame starts a new one.
    mutating func add(at date: Date, observedSeconds: Double, blinks: Int) -> MinuteRecord? {
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

/// The minutes on disk: one line each, in a plain text file that any spreadsheet opens.
///
///     ~/Library/Application Support/BlinkMonitor/history.csv
///     start,observed_seconds,blinks
///     2026-11-20T10:15:00Z,58.4,11
///
/// Only numbers are kept. No picture ever leaves the camera pipeline.
struct HistoryStore {

    let file: URL

    static var defaultFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("BlinkMonitor/history.csv")
    }

    private static let header = "start,observed_seconds,blinks"

    func append(_ record: MinuteRecord) {
        let files = FileManager.default
        if !files.fileExists(atPath: file.path) {
            try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (Self.header + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        let line = String(format: "%@,%.1f,%d\n", ISO8601DateFormatter().string(from: record.start),
                          record.observedSeconds, record.blinks)
        guard let handle = try? FileHandle(forWritingTo: file), let data = line.data(using: .utf8) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// The minutes recorded since `date`, oldest first.
    func load(since date: Date) -> [MinuteRecord] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let formatter = ISO8601DateFormatter()
        var records: [MinuteRecord] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",")
            guard fields.count == 3, let start = formatter.date(from: String(fields[0])),
                  let observed = Double(fields[1]), let blinks = Int(fields[2]), start >= date else { continue }
            records.append(MinuteRecord(start: start, observedSeconds: observed, blinks: blinks))
        }
        return records
    }
}

/// A day at a glance.
struct DaySummary: Equatable {
    var observedSeconds = 0.0
    var blinks = 0
    /// Minutes with a usable rate, and how many of them were under the threshold.
    var ratedMinutes = 0
    var lowMinutes = 0

    var ratePerMinute: Double? {
        observedSeconds >= 60 ? Double(blinks) / observedSeconds * 60 : nil
    }

    init(records: [MinuteRecord], threshold: Double) {
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
