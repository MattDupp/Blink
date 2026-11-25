import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

/// The optional summary banner: its words, and when the app shows it.
@MainActor
@Suite("The summary of the day, in the app")
struct SummaryTests {

    private func store() -> UserDefaults {
        let name = "local.blinkmonitor.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test("The sentence states numbers, says when there are too few, and gives no advice")
    func words() {
        let counted = DayDigest(day: .counted(seconds: 5 * 3600 + 600, rate: 13.2, aboveLimit: 81), breaksTaken: 6,
                                lastWeek: DayDigest.Week(seconds: 30 * 3600, rate: 11.8))
        let said = SummaryWords.body(counted, limit: 10) ?? ""
        #expect(said.hasPrefix("5 h 10 min at the screen, \(Format.rate(13.2)) blinks a minute, 81% of the time above your limit of 10."))
        #expect(said.contains("6 look-away breaks taken.") && said.hasSuffix("The seven days before: 30 h at the screen, \(Format.rate(11.8)) blinks a minute."))
        #expect(SummaryWords.body(DayDigest(day: .tooLittle(seconds: 20 * 60)), limit: 10) == "20 min at the screen: too little to give a rate.")
        #expect(SummaryWords.body(DayDigest(day: .notAtScreen, breaksTaken: 2), limit: 10) == nil, "a day off gets no banner")
        #expect(SummaryWords.body(DayDigest(day: .counted(seconds: 3600, rate: 9, aboveLimit: nil), breaksTaken: 1), limit: 10)
                == "1 h at the screen, \(Format.rate(9)) blinks a minute. 1 look-away break taken.")
        for word in ["should", "try", "good", "bad", "well done", "too low", "healthy"] {
            #expect(!said.lowercased().contains(word), "\(word)")
        }
        // An hour after the working hours would never show: Settings says so.
        #expect(SummaryWords.isHeldBack(hour: 19, by: .usual) && !SummaryWords.isHeldBack(hour: 17, by: .usual))
        #expect(!SummaryWords.isHeldBack(hour: 19, by: nil))
        let night = WorkingHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 6), weekdays: [2])
        #expect(!SummaryWords.isHeldBack(hour: 23, by: night) && !SummaryWords.isHeldBack(hour: 5, by: night) && SummaryWords.isHeldBack(hour: 12, by: night))
    }

    @Test("Off by default; on, it is shown once from its hour on, waits for the gate, and is silent about an empty day")
    func shownOnce() {
        let defaults = store()
        let preferences = Preferences(defaults: defaults)
        #expect(!preferences.summaryOn && preferences.summaryHour == 17 && !preferences.hasChoices)
        let reminders = ReminderController(preferences: preferences)
        var shown: [String] = []
        reminders.onSummary = { shown.append($0) }
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date()
        }
        let minutes = (0..<120).map { MinuteRecord(start: at(9).addingTimeInterval(Double($0) * 60), observedSeconds: 60, blinks: 12) }

        reminders.summaryIfDue(minutes: minutes, now: at(17, 1))
        #expect(shown.isEmpty, "off: nothing changes for whoever touches nothing")
        preferences.summaryOn = true
        reminders.summaryIfDue(minutes: minutes, now: at(16, 59))
        #expect(shown.isEmpty, "not before its hour")
        // Quiet holds it back; it comes when Quiet is over, the same day.
        reminders.setQuiet(until: at(17, 30))
        reminders.summaryIfDue(minutes: minutes, now: at(17, 1))
        #expect(shown.isEmpty)
        // So does something the person is in the middle of.
        reminders.busy = { BannerGate.Busy(blinkBreak: true) }
        reminders.summaryIfDue(minutes: minutes, now: at(17, 31))
        #expect(shown.isEmpty)
        reminders.busy = { .free }
        reminders.summaryIfDue(minutes: minutes, now: at(17, 32))
        #expect(shown.count == 1 && shown[0].hasPrefix("2 h at the screen"))
        #expect(!reminders.mayShowRoutineBanner(now: at(17, 33)), "it takes its place in the two minutes between banners")
        reminders.summaryIfDue(minutes: minutes, now: at(18))
        #expect(shown.count == 1, "once a day")
        #expect(Preferences(defaults: defaults).summaryShownDay == "2026-11-20", "and not again after a relaunch")
        // The next day, nothing counted: no banner, and it is not asked for again that day.
        reminders.summaryIfDue(minutes: minutes, now: at(17, 5, day: 21))
        #expect(shown.count == 1 && preferences.summaryShownDay == "2026-11-21")
        // Reset to Defaults switches it off.
        preferences.resetChoices()
        #expect(!preferences.summaryOn && !preferences.hasChoices)
    }
}
