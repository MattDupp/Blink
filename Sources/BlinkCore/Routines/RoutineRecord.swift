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
        /// You took back a `done` pressed by mistake: it cancels the latest `done` of the
        /// same slot. (The record only grows: a line is never removed.)
        case undone
        /// A timer was started for it. Kept for the record only: nothing is decided from it.
        case started
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
/// For a routine counted by the week it is the day alone, "2026-11-20": what is counted is
/// "done on that day", whatever the hour.
/// Lines are only ever added: what is due is worked out from them each time it is asked
/// (`RoutineDay`), so there is no "state" file that could disagree with the record.
public typealias RoutineStore = RecordFile<RoutineEvent>

extension RoutineEvent: RecordLine {
    public static let header = "at,routine,slot,action,until"

    public var fields: [String] {
        [RecordDates.string(at), CSVAppender.safe(routine), CSVAppender.safe(slot), action.rawValue,
         until.map(RecordDates.string) ?? ""]
    }

    public init?(fields: [String]) {
        guard fields.count == 5, let at = RecordDates.date(fields[0]), let action = Action(rawValue: fields[3]) else { return nil }
        self.init(at: at, routine: fields[1], slot: fields[2], action: action, until: RecordDates.date(fields[4]))
    }
}

extension RecordFile where Line == RoutineEvent {
    public static var defaultFile: URL {
        HistoryStore.applicationFolder.appendingPathComponent("routines.csv")
    }
}
