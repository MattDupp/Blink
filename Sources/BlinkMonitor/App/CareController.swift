import SwiftUI
import BlinkCore

/// Keeps the break log: the look-away breaks taken or skipped, the blink breaks finished
/// and the blink reminders shown (`CareStore`, in BlinkCore). The History window counts
/// them under "Kept in these seven days".
///
/// It only writes down what the app already did or showed. Nothing is decided from it:
/// no reminder comes sooner or later because of a line here.
@MainActor
final class CareController: ObservableObject {

    /// The lines of the weeks the History window can show.
    @Published private(set) var events: [CareEvent]
    /// The routine log of the same weeks, read while the History window is open. The
    /// routines themselves keep the last days only (`RoutineController.events`).
    @Published private(set) var routineLog: [RoutineEvent]?

    let store: CareStore

    init(store: CareStore = CareStore(file: CareStore.defaultFile), now: Date = Date(), calendar: Calendar = .current) {
        self.store = store
        events = store.load(since: HistoryWeeks.week(HistoryWeeks.shown - 1, now: now, calendar: calendar).start)
    }

    /// A log of its own in the temporary folder, emptied at each start: the demo, the
    /// screenshots and the tests never write to the user's real one.
    static func scratch() -> CareController {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-sample-breaks.csv")
        try? FileManager.default.removeItem(at: file)
        return CareController(store: CareStore(file: file))
    }

    func record(_ event: CareEvent) {
        events.append(event)
        store.append(event)
    }

    func record(_ kind: CareEvent.Kind, now: Date = Date()) {
        record(CareEvent(at: now, kind: kind))
    }

    /// Erases the break log, on disk and in memory.
    func erase() {
        if store.erase() { events = [] }
    }

    /// The History window opens, or closes.
    func readRoutineLog(_ routines: RoutineStore, now: Date = Date(), calendar: Calendar = .current) {
        routineLog = routines.load(since: HistoryWeeks.week(HistoryWeeks.shown - 1, now: now, calendar: calendar).start)
    }

    func forgetRoutineLog() {
        routineLog = nil
    }

    /// States the log, for the screenshots and the demo.
    func state(events: [CareEvent], routineLog: [RoutineEvent]? = nil) {
        self.events = events
        self.routineLog = routineLog
    }
}

/// The words of "Kept in these seven days" and of the one comparison under it.
enum KeptWords {
    static let title = "Kept in these seven days"

    /// One short line per kind of thing, only for what happened: "14 look-away breaks
    /// taken (2 long), 3 skipped or cut short".
    static func lines(_ kept: Kept) -> [(symbol: String, text: String)] {
        var lines: [(String, String)] = []
        if kept.breaksTaken > 0 || kept.breaksNotTaken > 0 {
            var text = "\(Format.count(kept.breaksTaken, "look-away break")) taken"
            if kept.longBreaks > 0 { text += " (\(kept.longBreaks) long)" }
            if kept.breaksNotTaken > 0 { text += ", \(kept.breaksNotTaken) skipped or cut short" }
            lines.append(("eye", text))
        }
        if kept.blinkBreaks > 0 || kept.blinkReminders > 0 {
            var parts: [String] = []
            if kept.blinkBreaks > 0 { parts.append("\(Format.count(kept.blinkBreaks, "blink break")) finished") }
            if kept.blinkReminders > 0 { parts.append("\(Format.count(kept.blinkReminders, "blink reminder")) shown") }
            lines.append(("bell", parts.joined(separator: ", ")))
        }
        if kept.routinesDone > 0 {
            lines.append(("checkmark.circle", "Routines marked done \(kept.routinesDone == 1 ? "once" : "\(kept.routinesDone.formatted()) times")"))
        }
        return lines
    }

    /// The comparison: two rates of the person's own, and the plain statement that they
    /// explain nothing. No cause, no promise, no advice.
    static func finding(_ finding: KeptFinding) -> String {
        "On the \(Format.count(finding.daysWith, "day")) with \(finding.breaks) or more look-away breaks: "
            + "\(Format.rate(finding.rateWith)) blinks a minute. On the \(finding.daysWithout) other days: \(Format.rate(finding.rateWithout)). "
            + "Your own numbers, side by side: they do not say why."
    }

    /// The row in the Privacy tab.
    static let fileTitle = "Break log"
    static let fileDetail = "The look-away breaks you took or skipped, the blink breaks you finished and the blink reminders shown, one line each time."
}
