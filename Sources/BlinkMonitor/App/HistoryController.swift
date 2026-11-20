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

    /// `minutes`: what is already known (the screenshots start from made-up minutes;
    /// the real app starts empty and calls `load`).
    init(store: HistoryStore = HistoryStore(file: HistoryStore.defaultFile), minutes: [MinuteRecord] = []) {
        self.store = store
        self.minutes = minutes
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
        var records = minutes.filter { calendar.isDate($0.start, inSameDayAs: day) }
        if let currentMinute, calendar.isDate(currentMinute.start, inSameDayAs: day) { records.append(currentMinute) }
        return records
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

    /// The last `count` days, oldest first, today last.
    func lastDays(_ count: Int, threshold: Double, now: Date = Date(),
                  calendar: Calendar = .current) -> [(day: Date, summary: DaySummary)] {
        (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)).map {
                ($0, summary(of: $0, threshold: threshold))
            }
        }
    }
}
