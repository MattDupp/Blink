import Foundation
import Testing
@testable import BlinkCore

/// The weeks the History window pages through, on dates written by hand.
@Suite("The weeks of the history")
struct HistoryWeeksTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        return calendar
    }

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private func minute(_ start: Date, blinks: Int = 12) -> MinuteRecord {
        MinuteRecord(start: start, observedSeconds: 60, blinks: blinks)
    }

    @Test("Week 0 is today and the six days before; week 1 ends where it begins")
    func boundaries() {
        // Friday 20 November 2026, 16:42.
        let now = at(2026, 11, 20, 16, 42)
        let last = HistoryWeeks.week(0, now: now, calendar: calendar)
        #expect(last.days == (14...20).map { at(2026, 11, $0) })
        #expect(last.end == at(2026, 11, 21) && last.isInProgress)
        let before = HistoryWeeks.week(1, now: now, calendar: calendar)
        #expect(before.days == (7...13).map { at(2026, 11, $0) })
        #expect(before.end == last.start && !before.isInProgress)
        // The last minute of one week and the first of the next.
        #expect(before.contains(at(2026, 11, 13, 23, 59)) && !last.contains(at(2026, 11, 13, 23, 59)))
        #expect(last.contains(at(2026, 11, 14)) && !before.contains(at(2026, 11, 14)))
        // No minute is in two weeks, and none between two weeks is in no week.
        let weeks = HistoryWeeks.weeks(now: now, calendar: calendar)
        #expect(weeks.count == 12 && weeks.last == last && weeks.first?.index == 11)
        for (older, newer) in zip(weeks, weeks.dropFirst()) { #expect(older.end == newer.start) }
        #expect(weeks.first?.start == at(2026, 8, 29))
    }

    @Test("A week still in progress: later today is still in it, tomorrow is not")
    func inProgress() {
        let morning = at(2026, 11, 20, 8)
        let week = HistoryWeeks.week(0, now: morning, calendar: calendar)
        #expect(week.contains(at(2026, 11, 20, 23, 59)), "a minute counted tonight belongs to these seven days")
        #expect(!week.contains(at(2026, 11, 21)))
        // The same week whatever the hour of the day it is asked at.
        #expect(week == HistoryWeeks.week(0, now: at(2026, 11, 20, 23, 59), calendar: calendar))
        // At midnight everything moves by one day.
        #expect(HistoryWeeks.week(0, now: at(2026, 11, 21), calendar: calendar).start == at(2026, 11, 15))
    }

    @Test("Over a year's end, and over the night the clocks change, days still start at midnight")
    func yearEndAndClockChange() {
        // Saturday 2 January 2027: the last seven days begin on 27 December.
        let january = HistoryWeeks.week(0, now: at(2027, 1, 2, 10), calendar: calendar)
        #expect(january.days.first == at(2026, 12, 27) && january.days[4] == at(2026, 12, 31) && january.days[5] == at(2027, 1, 1))
        #expect(HistoryWeeks.week(1, now: at(2027, 1, 2, 10), calendar: calendar).days.last == at(2026, 12, 26))
        // Sunday 25 October 2026 has 25 hours in Paris. Seven days are not 7 x 24 hours.
        let october = HistoryWeeks.week(0, now: at(2026, 10, 28, 9), calendar: calendar)
        #expect(october.days == (22...28).map { at(2026, 10, $0) })
        #expect(october.end.timeIntervalSince(october.start) == 7 * 86_400 + 3600)
        // Sunday 28 March 2027 has 23.
        let march = HistoryWeeks.week(0, now: at(2027, 3, 30, 9), calendar: calendar)
        #expect(march.days == (24...30).map { at(2027, 3, $0) })
        #expect(march.end.timeIntervalSince(march.start) == 7 * 86_400 - 3600)
    }

    @Test("An empty week has no rate, and the weeks around it keep theirs")
    func emptyWeek() {
        let now = at(2026, 11, 20, 16)
        // Counted this week and three weeks ago; nothing in between.
        let records = (0..<30).map { minute(at(2026, 11, 18, 10, $0), blinks: 12) }
            + (0..<30).map { minute(at(2026, 10, 28, 10, $0), blinks: 8) }
        let weeks = HistoryWeeks.weeks(4, now: now, calendar: calendar)
        let summaries = HistoryWeeks.summaries(of: weeks, records: records, threshold: 10)
        #expect(summaries.map(\.ratePerMinute) == [8, nil, nil, 12])
        #expect(summaries[1].observedSeconds == 0 && summaries[0].lowShare == 1 && summaries[3].lowShare == 0)
        #expect(weeks[1].records(in: records).isEmpty)
    }

    @Test("The arrow to an earlier week leads somewhere only when something is recorded there")
    func hasEarlier() {
        let now = at(2026, 11, 20, 16)
        let thisWeek = HistoryWeeks.week(0, now: now, calendar: calendar)
        let recent = [minute(at(2026, 11, 19, 10))]
        #expect(!HistoryWeeks.hasEarlier(than: thisWeek, records: recent, now: now, calendar: calendar), "a first week: nothing before")
        let old = recent + [minute(at(2026, 10, 1, 10))]
        #expect(HistoryWeeks.hasEarlier(than: thisWeek, records: old, now: now, calendar: calendar))
        // From the week that holds 1 October back, there is nothing more.
        let holding = HistoryWeeks.weeks(now: now, calendar: calendar).first { $0.contains(at(2026, 10, 1, 10)) }
        #expect(holding.map { !HistoryWeeks.hasEarlier(than: $0, records: old, now: now, calendar: calendar) } == true)
        // Older than the twelve weeks shown: not offered, and the last week has no arrow.
        let ancient = recent + [minute(at(2026, 5, 1, 10))]
        #expect(!HistoryWeeks.hasEarlier(than: thisWeek, records: ancient, now: now, calendar: calendar))
        let twelfth = HistoryWeeks.week(11, now: now, calendar: calendar)
        #expect(!HistoryWeeks.hasEarlier(than: twelfth, records: ancient, now: now, calendar: calendar))
        // A minute in which the eyes were never read is not a record.
        let unread = recent + [MinuteRecord(start: at(2026, 10, 1, 10), observedSeconds: 0, blinks: 0)]
        #expect(!HistoryWeeks.hasEarlier(than: thisWeek, records: unread, now: now, calendar: calendar))
    }
}
