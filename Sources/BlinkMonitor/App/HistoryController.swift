import SwiftUI
import BlinkCore

/// The minutes of the last days: loaded once from disk, extended as minutes end.
@MainActor
final class HistoryController: ObservableObject {

    /// How far back the app looks (the history window shows a week).
    static let daysKept = 8

    /// Finished minutes, oldest first.
    @Published private(set) var minutes: [MinuteRecord]
    /// The minute being filled.
    @Published private(set) var currentMinute: MinuteRecord?

    let store: HistoryStore

    /// The minutes of the earlier weeks, read from the file while the History window is
    /// open (`loadEarlier`). Nil: not read. The app itself only needs the last days, so
    /// months of minutes are not kept in memory all day for a window that is closed.
    @Published private(set) var earlier: [MinuteRecord]?
    /// When `earlier` was read: what was counted since is in `minutes`.
    private var earlierReadAt: Date?

    /// `minutes`, `current`: what is already known (the screenshots start from made-up
    /// minutes; the real app starts empty and calls `load`).
    init(store: HistoryStore, minutes: [MinuteRecord] = [],
         current: MinuteRecord? = nil) {
        self.store = store
        self.minutes = minutes
        currentMinute = current
    }

    func load(now: Date = Date()) {
        minutes = store.load(since: now.addingTimeInterval(-Double(Self.daysKept) * 86_400))
    }

    func minuteEnded(_ minute: MinuteRecord, now: Date = Date()) {
        // A minute in which the eyes were never read (you were away) is not a record.
        guard minute.observedSeconds >= 1 else { return }
        minutes.append(minute)
        store.append(minute)
        let oldest = now.addingTimeInterval(-Double(Self.daysKept) * 86_400)
        if let first = minutes.first, first.start < oldest {
            minutes.removeAll { $0.start < oldest }
        }
    }

    /// The app is quitting: the minute being filled is written as far as it got, when it
    /// holds enough to have a rate. It was lost before, up to a minute at each quit.
    func saveCurrentMinute(now: Date = Date()) {
        guard let current = currentMinute, current.ratePerMinute != nil else { return }
        minuteEnded(current, now: now)
        currentMinute = nil
    }

    /// Forgets every recorded minute, on disk too. The minute being filled goes on.
    func erase() {
        if store.erase() {
            minutes = []
            if earlier != nil { earlier = [] }
        }
    }

    /// The History window opens: read the weeks it can go back to.
    func loadEarlier(now: Date = Date(), calendar: Calendar = .current) {
        earlier = store.load(since: HistoryWeeks.week(HistoryWeeks.shown - 1, now: now, calendar: calendar).start)
        earlierReadAt = now
    }

    /// The same, read away from the main thread: after a year or two the file holds
    /// hundreds of thousands of lines, and the window must not wait for them to open.
    /// Until they arrive the window shows the last seven days, as it always did.
    func loadEarlierInBackground(now: Date = Date(), calendar: Calendar = .current) {
        let store = self.store
        let since = HistoryWeeks.week(HistoryWeeks.shown - 1, now: now, calendar: calendar).start
        wantsEarlier = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let records = store.load(since: since)
            await self?.arrived(earlier: records, readAt: now)
        }
    }
    private var wantsEarlier = false

    private func arrived(earlier records: [MinuteRecord], readAt: Date) {
        // Closed again before the file was read: nothing to keep.
        guard wantsEarlier else { return }
        earlier = records
        earlierReadAt = readAt
    }

    /// The window closed.
    func forgetEarlier() {
        wantsEarlier = false
        earlier = nil
        earlierReadAt = nil
    }

    /// States the earlier weeks, for the screenshots and the demo.
    func state(earlier: [MinuteRecord], readAt: Date) {
        self.earlier = earlier
        earlierReadAt = readAt
    }

    /// Every minute known in the weeks the window shows: what the file held when the
    /// window opened, what was counted since, and the minute in progress.
    func allRecords() -> [MinuteRecord] {
        guard let earlier, let earlierReadAt else { return minutes + [currentMinute].compactMap { $0 } }
        let readUpTo = earlier.last?.start ?? earlierReadAt.addingTimeInterval(-86_400 * 400)
        return earlier + minutes.filter { $0.start > readUpTo } + [currentMinute].compactMap { $0 }.filter { $0.start > readUpTo }
    }

    /// The seven days of a week with their summaries, oldest first.
    func days(of week: HistoryWeek, threshold: Double, calendar: Calendar = .current) -> [(day: Date, summary: DaySummary)] {
        let records = week.records(in: allRecords())
        return week.days.map { ($0, DaySummary(records: records.on($0, calendar: calendar), threshold: threshold)) }
    }

    /// The minute being filled changes with every frame; the windows are told about once
    /// a second (or when a blink lands in it), which is all they can show.
    func update(current: MinuteRecord?) {
        guard let current else { return }
        let shown = currentMinute
        let worthShowing = current.start != shown?.start
            || current.blinks != shown?.blinks
            || current.observedSeconds - (shown?.observedSeconds ?? 0) >= 1
        if worthShowing { currentMinute = current }
    }

    /// The records of one calendar day, including the minute being filled.
    func records(on day: Date, calendar: Calendar = .current) -> [MinuteRecord] {
        // With the earlier weeks read (the History window is open), any day can be asked for.
        if earlier != nil { return allRecords().on(day, calendar: calendar) }
        return minutes.on(day, calendar: calendar) + [currentMinute].compactMap { $0 }.on(day, calendar: calendar)
    }

    func summary(of day: Date, threshold: Double) -> DaySummary {
        DaySummary(records: records(on: day), threshold: threshold)
    }

    /// One day cut into its 24 hours (index 0 = midnight to 1 am).
    func hours(of day: Date, threshold: Double, calendar: Calendar = .current) -> [DaySummary] {
        var byHour = [[MinuteRecord]](repeating: [], count: 24)
        for record in records(on: day, calendar: calendar) {
            byHour[calendar.component(.hour, from: record.start)].append(record)
        }
        return byHour.map { DaySummary(records: $0, threshold: threshold) }
    }
}
