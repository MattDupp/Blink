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
public struct EyeNoteStore {

    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public static var defaultFile: URL {
        HistoryStore.applicationFolder.appendingPathComponent("eye-notes.csv")
    }

    private static let header = "day,at,feeling"

    @discardableResult
    public func append(_ note: EyeNote) -> Bool {
        do {
            return try CSVAppender(url: file, header: Self.header).append([
                RoutineStore.safe(note.day), ISO8601DateFormatter().string(from: note.at), note.feeling.rawValue,
            ])
        } catch {
            Log.storage.error("Eye notes not opened: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Every note, oldest first. Lines that cannot be read are skipped.
    public func load() -> [EyeNote] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let formatter = ISO8601DateFormatter()
        var notes: [EyeNote] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let at = formatter.date(from: fields[1]), let feeling = EyeFeeling(rawValue: fields[2]) else { continue }
            notes.append(EyeNote(day: fields[0], at: at, feeling: feeling))
        }
        return notes
    }

    @discardableResult
    public func erase() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return true
        } catch {
            Log.storage.error("Eye notes not erased: \(error.localizedDescription, privacy: .public)")
            return false
        }
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
