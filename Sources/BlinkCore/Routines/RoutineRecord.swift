import Foundation

/// One line of the routine record: something that happened to one planned time.
public struct RoutineEvent: Equatable {

    public enum Action: String {
        /// A banner was shown for it. Kept so that the app does not show it again after a
        /// relaunch, and repeats it once only.
        case shown
        /// You put it off, until `until`.
        case later
        /// You did it.
        case done
        /// Its next time came and it had not been done: it was dropped.
        case missed
    }

    /// When this happened.
    public let at: Date
    /// The routine's `id`.
    public let routine: String
    /// The planned time this is about, as `RoutineSlot.key` names it.
    public let slot: String
    public let action: Action
    /// For `later`: until when.
    public let until: Date?

    public init(at: Date, routine: String, slot: String, action: Action, until: Date? = nil) {
        self.at = at
        self.routine = routine
        self.slot = slot
        self.action = action
        self.until = until
    }
}

/// The routine record on disk, beside the blink history:
///
///     ~/Library/Application Support/BlinkMonitor/routines.csv
///     at,routine,slot,action,until
///     2026-11-20T08:02:10Z,eye-drops,2026-11-20T08:00,shown,
///     2026-11-20T08:03:41Z,eye-drops,2026-11-20T08:00,done,
///
/// `slot` is a day and a time ON THE WALL CLOCK, with no time zone (see `RoutineSlot.key`).
/// Lines are only ever added: what is due is worked out from them each time it is asked
/// (`RoutineDay`), so there is no "state" file that could disagree with the record.
public struct RoutineStore {

    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public static var defaultFile: URL {
        HistoryStore.applicationFolder.appendingPathComponent("routines.csv")
    }

    private static let header = "at,routine,slot,action,until"

    /// Adds one line at the end of the file. Returns false (and logs why) on failure.
    @discardableResult
    public func append(_ event: RoutineEvent) -> Bool {
        let formatter = ISO8601DateFormatter()
        do {
            return try CSVAppender(url: file, header: Self.header).append([
                formatter.string(from: event.at), Self.safe(event.routine), Self.safe(event.slot),
                event.action.rawValue, event.until.map { formatter.string(from: $0) } ?? "",
            ])
        } catch {
            Log.storage.error("Routine record not opened: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// What happened since `date`, oldest first. Lines that cannot be read are skipped.
    public func load(since date: Date) -> [RoutineEvent] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let formatter = ISO8601DateFormatter()
        var events: [RoutineEvent] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let at = formatter.date(from: fields[0]), at >= date,
                  let action = RoutineEvent.Action(rawValue: fields[3]) else { continue }
            events.append(RoutineEvent(at: at, routine: fields[1], slot: fields[2], action: action,
                                       until: formatter.date(from: fields[4])))
        }
        return events
    }

    /// Removes the whole record. Returns false (and logs why) on failure.
    @discardableResult
    public func erase() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return true
        } catch {
            Log.storage.error("Routine record not erased: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// A comma or a line break in a field would shift every column after it.
    static func safe(_ field: String) -> String {
        String(field.map { $0 == "," || $0.isNewline ? "_" : $0 })
    }
}
