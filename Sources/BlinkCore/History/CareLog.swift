import Foundation

/// One line of the break log: something you did, or were asked, about your eyes.
public struct CareEvent: Equatable {

    public enum Kind: String, CaseIterable {
        /// A look-away break was taken (you looked away, or it ran to its end).
        case lookAway = "look-away-break"
        /// A long break was taken.
        case longBreak = "long-break"
        /// A break was skipped, with its button.
        case skipped = "break-skipped"
        /// You came back before a break was over.
        case cutShort = "break-cut-short"
        /// A blink break was finished: its ten blinks were counted.
        case blinkBreak = "blink-break"
        /// The banner "you blink too little" was shown.
        case blinkReminder = "blink-reminder"
    }

    public let at: Date
    public let kind: Kind
    /// For a long break: it grew out of a short one that is already on its own line, so
    /// the two are ONE break taken (the same rule as `BreakTally`).
    public let sameAbsence: Bool

    public init(at: Date, kind: Kind, sameAbsence: Bool = false) {
        self.at = at
        self.kind = kind
        self.sameAbsence = sameAbsence
    }

    /// How the end of a look-away break is written. Nil never happens today; a new
    /// ending would have to be given a line here.
    public init(_ outcome: BreakOutcome, at: Date) {
        switch outcome.ending {
        case .away, .onTrust:
            self.init(at: at, kind: outcome.kind == .long ? .longBreak : .lookAway, sameAbsence: outcome.sameAbsence)
        case .skipped:
            self.init(at: at, kind: .skipped)
        case .cutShort:
            self.init(at: at, kind: .cutShort)
        }
    }
}

/// The break log on disk, beside the history and the routine log:
///
///     ~/Library/Application Support/BlinkMonitor/breaks.csv
///     at,what,note
///     2026-11-20T10:20:05Z,look-away-break,
///     2026-11-20T11:02:40Z,blink-reminder,
///     2026-11-20T11:03:31Z,blink-break,
///
/// A file of its own: `history.csv` is read by the Python side too and its format does
/// not change. Lines are only ever added. Like the other two it holds times and words,
/// never a picture, and it never leaves this Mac.
public struct CareStore {

    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public static var defaultFile: URL {
        HistoryStore.applicationFolder.appendingPathComponent("breaks.csv")
    }

    private static let header = "at,what,note"
    private static let sameAbsence = "same-absence"

    @discardableResult
    public func append(_ event: CareEvent) -> Bool {
        do {
            return try CSVAppender(url: file, header: Self.header).append([
                ISO8601DateFormatter().string(from: event.at), event.kind.rawValue, event.sameAbsence ? Self.sameAbsence : "",
            ])
        } catch {
            Log.storage.error("Break log not opened: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// What happened since `date`, oldest first. Lines that cannot be read are skipped.
    public func load(since date: Date) -> [CareEvent] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let formatter = ISO8601DateFormatter()
        var events: [CareEvent] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let at = formatter.date(from: fields[0]), at >= date,
                  let kind = CareEvent.Kind(rawValue: fields[1]) else { continue }
            events.append(CareEvent(at: at, kind: kind, sameAbsence: fields[2] == Self.sameAbsence))
        }
        return events
    }

    @discardableResult
    public func erase() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return true
        } catch {
            Log.storage.error("Break log not erased: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// What was kept in seven days: counted from the break log and the routine log.
public struct Kept: Equatable {
    /// Look-away breaks taken, long ones included. A short break that grew into a long
    /// one is one break.
    public var breaksTaken = 0
    public var longBreaks = 0
    /// Skipped, or cut short.
    public var breaksNotTaken = 0
    public var blinkBreaks = 0
    public var blinkReminders = 0
    /// Times a routine was marked done (a mark taken back is not counted).
    public var routinesDone = 0

    public var isEmpty: Bool { self == Kept() }

    public init() {}

    public init(week: HistoryWeek, care: [CareEvent], routines: [RoutineEvent]) {
        for event in care where week.contains(event.at) {
            switch event.kind {
            case .lookAway: breaksTaken += 1
            case .longBreak:
                longBreaks += 1
                if !event.sameAbsence { breaksTaken += 1 }
            case .skipped, .cutShort: breaksNotTaken += 1
            case .blinkBreak: blinkBreaks += 1
            case .blinkReminder: blinkReminders += 1
            }
        }
        let inWeek = routines.filter { week.contains($0.at) }
        routinesDone = max(0, inWeek.filter { $0.action == .done }.count - inWeek.filter { $0.action == .undone }.count)
    }
}

/// The one comparison the History window may state: your blink rate on the days with
/// more look-away breaks, beside your rate on the other days.
///
/// It is the person's own numbers set side by side, and nothing more. Days with more
/// breaks differ from the others in many ways (shorter days, other work), so the two
/// rates say nothing about why. The window's sentence says so, and gives no advice.
///
/// It is stated only when the numbers can bear it:
///   - a day counts when at least `minimumMinutes` were spent at the screen, and when it
///     is not before the first line of the break log (before it, breaks were not written
///     down, and "no line" would be read as "no break");
///   - today does not count: it is not over;
///   - the days are split at their median number of breaks, and each side needs at
///     least `minimumDays` days.
public struct KeptFinding: Equatable {

    public static let minimumDays = 5
    public static let minimumMinutes = 60.0

    /// "With N or more breaks".
    public let breaks: Int
    public let daysWith: Int
    public let rateWith: Double
    public let daysWithout: Int
    public let rateWithout: Double

    public init(breaks: Int, daysWith: Int, rateWith: Double, daysWithout: Int, rateWithout: Double) {
        self.breaks = breaks
        self.daysWith = daysWith
        self.rateWith = rateWith
        self.daysWithout = daysWithout
        self.rateWithout = rateWithout
    }

    public static func find(records: [MinuteRecord], care: [CareEvent], now: Date, calendar: Calendar) -> KeptFinding? {
        guard let logStarts = care.map(\.at).min() else { return nil }
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.startOfDay(for: logStarts)

        // One line per day: seconds at the screen, blinks, breaks taken.
        var days: [Date: (seconds: Double, blinks: Int, breaks: Int)] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.start)
            guard day >= firstDay, day < today else { continue }
            days[day, default: (0, 0, 0)].seconds += record.observedSeconds
            days[day, default: (0, 0, 0)].blinks += record.blinks
        }
        for event in care {
            let taken = event.kind == .lookAway || (event.kind == .longBreak && !event.sameAbsence)
            let day = calendar.startOfDay(for: event.at)
            if taken, days[day] != nil { days[day]?.breaks += 1 }
        }
        let counted = days.values.filter { $0.seconds >= minimumMinutes * 60 }
        guard counted.count >= 2 * minimumDays else { return nil }

        // Split at the median: "N or more" holds the upper half.
        let sorted = counted.map(\.breaks).sorted()
        let threshold = max(1, sorted[sorted.count / 2])
        let with = counted.filter { $0.breaks >= threshold }
        let without = counted.filter { $0.breaks < threshold }
        guard with.count >= minimumDays, without.count >= minimumDays else { return nil }
        func rate(_ days: [(seconds: Double, blinks: Int, breaks: Int)]) -> Double {
            Double(days.reduce(0) { $0 + $1.blinks }) / days.reduce(0) { $0 + $1.seconds } * 60
        }
        return KeptFinding(breaks: threshold, daysWith: with.count, rateWith: rate(with),
                           daysWithout: without.count, rateWithout: rate(without))
    }
}
