import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

/// The History window's earlier weeks, read from a file of the test's own.
@MainActor
@Suite("History beyond seven days")
struct HistoryWeeksControllerTests {

    @Test("The earlier weeks are read when the window opens, joined to what is counted since, and let go when it closes")
    func earlierWeeks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(file: folder.appendingPathComponent("history.csv"))
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 16)) ?? Date()
        func minute(daysBack: Int, _ offset: Int, blinks: Int) -> MinuteRecord {
            let day = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now)) ?? now
            return MinuteRecord(start: day.addingTimeInterval(10 * 3600 + Double(offset) * 60), observedSeconds: 60, blinks: blinks)
        }
        // On file: half a year ago (not shown), three weeks ago, and yesterday.
        var onFile = [minute(daysBack: 180, 0, blinks: 5)]
        onFile += (0..<20).map { minute(daysBack: 22, $0, blinks: 8) }
        onFile += (0..<20).map { minute(daysBack: 1, $0, blinks: 14) }
        for record in onFile { store.append(record) }
        let history = HistoryController(store: store)
        history.load(now: now)
        #expect(history.minutes.count == 20 && history.earlier == nil, "the app itself keeps the last days only")
        #expect(history.records(on: minute(daysBack: 22, 0, blinks: 0).start).isEmpty)

        history.loadEarlier(now: now)
        #expect(history.earlier?.count == 40, "twelve weeks back, no further")
        #expect(history.allRecords().count == 40, "yesterday is not counted twice")
        // A minute counted while the window is open is in, once.
        history.minuteEnded(MinuteRecord(start: now.addingTimeInterval(-60), observedSeconds: 60, blinks: 13), now: now)
        #expect(history.allRecords().count == 41)
        // Three weeks ago is the fourth week back, at 8 blinks a minute.
        let week = HistoryWeeks.week(3, now: now, calendar: calendar)
        let days = history.days(of: week, threshold: 10)
        #expect(days.count == 7 && days.compactMap(\.summary.ratePerMinute) == [8])
        #expect(history.records(on: minute(daysBack: 22, 0, blinks: 0).start).count == 20)
        #expect(HistoryWords.title(of: week) != "Last 7 days" && HistoryWords.title(of: HistoryWeeks.week(0, now: now, calendar: calendar)) == "Last 7 days")

        history.forgetEarlier()
        #expect(history.earlier == nil && history.allRecords().count == 21)
        // Erasing the history with the window open empties the weeks too.
        history.loadEarlier(now: now)
        history.erase()
        #expect(history.allRecords().isEmpty && history.earlier?.isEmpty == true)
    }
}
