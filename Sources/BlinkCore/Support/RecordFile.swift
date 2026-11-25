import Foundation

/// One line of a record file: what it writes, and how it is read back.
///
/// The app keeps four records of what happened, each a CSV file of its own beside the
/// others: the history (`MinuteRecord`), the break log (`CareEvent`), the eye notes
/// (`EyeNote`) and the routine log (`RoutineEvent`). Each used to carry its own copy of
/// append, load and erase, and the copies had begun to differ. A record now says only its
/// header and its fields; `RecordFile` does the rest, once.
public protocol RecordLine {
    /// The file's name, in the app's folder or in a scratch one.
    static var fileName: String { get }
    /// The file's first line: the names of the columns.
    static var header: String { get }
    /// The line's fields, in the header's order. Free text goes through `CSVAppender.safe`.
    var fields: [String] { get }
    /// The line read back from its fields; nil when they cannot be read.
    init?(fields: [String])
    /// When it happened: what `RecordFile.load(since:)` keeps or skips.
    var at: Date { get }
}

/// How the records write a moment: ISO 8601, in UTC ("2026-11-20T10:15:00Z").
public enum RecordDates {
    // An ISO8601DateFormatter can be shared between threads, and is costly to make.
    private static let formatter = ISO8601DateFormatter()

    public static func string(_ date: Date) -> String { formatter.string(from: date) }
    public static func date(_ text: String) -> Date? { formatter.date(from: text) }
}

/// A record file: lines are only ever added, read back oldest first, and the whole file
/// can be erased. A file that does not exist yet is an empty record, not an error.
public struct RecordFile<Line: RecordLine> {

    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// The record's file in `folder`.
    public init(in folder: URL) {
        file = folder.appendingPathComponent(Line.fileName)
    }

    /// The folder the app keeps its own files in: ~/Library/Application Support/BlinkMonitor.
    public static var applicationFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("BlinkMonitor", isDirectory: true)
    }

    /// The record's file among the app's own.
    public static var defaultFile: URL {
        applicationFolder.appendingPathComponent(Line.fileName)
    }

    /// Adds one line at the end of the file. Returns false (and logs why) on failure.
    @discardableResult
    public func append(_ line: Line) -> Bool {
        do {
            return try CSVAppender(url: file, header: Line.header).append(line.fields)
        } catch {
            // The error's text can hold the file's path, and so the account's name.
            Log.storage.error("\(file.lastPathComponent, privacy: .public) not opened: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// The lines that happened at `date` or later, oldest first. Lines that cannot be
    /// read are skipped.
    public func load(since date: Date = .distantPast) -> [Line] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            Line(fields: line.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
        }
        .filter { $0.at >= date }
    }

    /// Removes the whole file. Returns false (and logs why) on failure.
    @discardableResult
    public func erase() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return true
        } catch {
            Log.storage.error("\(file.lastPathComponent, privacy: .public) not erased: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
