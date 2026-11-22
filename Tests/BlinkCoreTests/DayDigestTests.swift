import Foundation
import Testing
@testable import BlinkCore

/// The summary of the day, on days written by hand.
@Suite("The summary of the day")
struct DayDigestTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        return calendar
    }

    /// November 2026: the 20th is a Friday, the 23rd a Monday.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private func minutes(_ day: Int, from hour: Int, count: Int, blinks: Int) -> [MinuteRecord] {
        (0..<count).map { MinuteRecord(start: at(day, hour).addingTimeInterval(Double($0) * 60), observedSeconds: 60, blinks: blinks) }
    }

    @Test("A counted day: time at the screen, the rate, the share above the limit, the breaks")
    func counted() {
        // Three hours at 12 a minute, one at 8: 11 a minute, three quarters above a limit of 10.
        let records = minutes(20, from: 9, count: 180, blinks: 12) + minutes(20, from: 14, count: 60, blinks: 8)
        let digest = DayDigest(records: records, limit: 10, breaksTaken: 6, now: at(20, 17), calendar: calendar)
        #expect(digest.day == .counted(seconds: 4 * 3600, rate: 11, aboveLimit: 75))
        #expect(digest.breaksTaken == 6 && digest.lastWeek == nil, "Friday: no line about last week")
    }

    @Test("Too little time at the screen gives no rate; none at all gives nothing; yesterday is not today")
    func tooLittle() {
        let short = minutes(20, from: 9, count: 29, blinks: 3)
        #expect(DayDigest(records: short, limit: 10, breaksTaken: 0, now: at(20, 17), calendar: calendar).day == .tooLittle(seconds: 29 * 60))
        // Thirty minutes is enough.
        let enough = minutes(20, from: 9, count: 30, blinks: 12)
        #expect(DayDigest(records: enough, limit: 10, breaksTaken: 0, now: at(20, 17), calendar: calendar).day
                == .counted(seconds: 1800, rate: 12, aboveLimit: 100))
        // A long day yesterday, nothing today.
        let yesterday = minutes(19, from: 9, count: 300, blinks: 12)
        #expect(DayDigest(records: yesterday, limit: 10, breaksTaken: 0, now: at(20, 17), calendar: calendar).day == .notAtScreen)
    }

    @Test("On a Monday, a line for the seven days that ended yesterday, when enough was counted in them")
    func monday() {
        // Monday the 23rd. Last week: Tuesday the 17th and Friday the 20th, 2 hours each.
        let lastWeek = minutes(17, from: 9, count: 120, blinks: 10) + minutes(20, from: 9, count: 120, blinks: 14)
        let today = minutes(23, from: 9, count: 60, blinks: 12)
        let older = minutes(15, from: 9, count: 120, blinks: 30)       // Sunday the 15th: eight days back, not in it
        let digest = DayDigest(records: older + lastWeek + today, limit: 10, breaksTaken: 0, now: at(23, 17), calendar: calendar)
        #expect(digest.lastWeek == DayDigest.Week(seconds: 4 * 3600, rate: 12))
        #expect(digest.day == .counted(seconds: 3600, rate: 12, aboveLimit: 100), "today's minutes are not in last week's line")
        // Under two hours in the whole week: no line.
        let thin = minutes(20, from: 9, count: 100, blinks: 14)
        #expect(DayDigest(records: thin + today, limit: 10, breaksTaken: 0, now: at(23, 17), calendar: calendar).lastWeek == nil)
        // Tuesday: no line, whatever was counted.
        #expect(DayDigest(records: lastWeek, limit: 10, breaksTaken: 0, now: at(24, 17), calendar: calendar).lastWeek == nil)
    }

    @Test("Due once a day, from the chosen hour on, and never for a day that is over")
    func schedule() {
        let key = SummarySchedule.key(of: at(20, 17), calendar: calendar)
        #expect(key == "2026-11-20")
        #expect(!SummarySchedule.isDue(now: at(20, 16, 59), hour: 17, lastShown: nil, calendar: calendar))
        #expect(SummarySchedule.isDue(now: at(20, 17), hour: 17, lastShown: nil, calendar: calendar))
        #expect(SummarySchedule.isDue(now: at(20, 23, 30), hour: 17, lastShown: "2026-11-19", calendar: calendar), "asleep at five: said when back")
        #expect(!SummarySchedule.isDue(now: at(20, 18), hour: 17, lastShown: key, calendar: calendar), "once")
        // The Mac slept through Friday evening: on Saturday morning nothing of Friday is said.
        #expect(!SummarySchedule.isDue(now: at(21, 9), hour: 17, lastShown: "2026-11-19", calendar: calendar))
        #expect(SummarySchedule.isDue(now: at(21, 17), hour: 17, lastShown: key, calendar: calendar))
    }
}
