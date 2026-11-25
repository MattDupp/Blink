import Foundation

/// How the eyes feel, in the person's own judgement: one of four plain words.
///
/// This is a note, not a measurement and not a symptom scale. The app stores it and
/// shows it back. It never interprets it, never sets it against the blink rate, and
/// never draws a conclusion or gives advice from it.
public enum EyeFeeling: String, CaseIterable, Identifiable {
    case fine
    case aLittleTired = "a-little-tired"
    case tired
    case veryTired = "very-tired"

    public var id: String { rawValue }
}

/// One answer to the evening question.
public struct EyeNote: Equatable {
    /// The day it is about, on the wall clock: "2026-11-20" (`SummarySchedule.key`).
    public let day: String
    public let at: Date
    public let feeling: EyeFeeling

    public init(day: String, at: Date, feeling: EyeFeeling) {
        self.day = day
        self.at = at
        self.feeling = feeling
    }

    public init(feeling: EyeFeeling, at: Date, calendar: Calendar) {
        self.init(day: SummarySchedule.key(of: at, calendar: calendar), at: at, feeling: feeling)
    }
}

/// The notes on disk, in a file of their own beside the history:
///
///     ~/Library/Application Support/BlinkMonitor/eye-notes.csv
///     day,at,feeling
///     2026-11-20,2026-11-20T17:02:10Z,a-little-tired
///
/// Lines are only ever added. An answer changed the same day is a second line, and the
/// later one is the day's note (`EyeNotes.byDay`). The file never leaves this Mac.
public typealias EyeNoteStore = RecordFile<EyeNote>

extension EyeNote: RecordLine {
    public static let header = "day,at,feeling"

    public var fields: [String] {
        [CSVAppender.safe(day), RecordDates.string(at), feeling.rawValue]
    }

    public init?(fields: [String]) {
        guard fields.count == 3, let at = RecordDates.date(fields[1]), let feeling = EyeFeeling(rawValue: fields[2]) else { return nil }
        self.init(day: fields[0], at: at, feeling: feeling)
    }
}

extension RecordFile where Line == EyeNote {
    public static var defaultFile: URL {
        HistoryStore.applicationFolder.appendingPathComponent("eye-notes.csv")
    }
}

public enum EyeNotes {

    /// The note of each day: the last one written for it.
    public static func byDay(_ notes: [EyeNote]) -> [String: EyeFeeling] {
        var days: [String: EyeFeeling] = [:]
        for note in notes { days[note.day] = note.feeling }
        return days
    }

    /// One entry per day of a week, in the week's order; nil where nothing was noted.
    public static func row(for week: HistoryWeek, notes: [EyeNote], calendar: Calendar) -> [EyeFeeling?] {
        let days = byDay(notes)
        return week.days.map { days[SummarySchedule.key(of: $0, calendar: calendar)] }
    }
}
