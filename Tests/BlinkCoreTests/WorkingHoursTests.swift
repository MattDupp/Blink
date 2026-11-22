import Foundation
import Testing
@testable import BlinkCore

/// "Quiet outside working hours", on moments written by hand.
@Suite("Working hours")
struct WorkingHoursTests {

    /// A calendar of its own: the tests must not depend on where this Mac is.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        return calendar
    }

    /// November 2026: the 16th is a Monday, the 20th a Friday, the 21st a Saturday.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    @Test("Monday to Friday, nine to six: inside from the first minute, outside from the last")
    func office() {
        let hours = WorkingHours.usual
        #expect(!hours.contains(at(16, 8, 59), calendar: calendar))
        #expect(hours.contains(at(16, 9, 0), calendar: calendar))
        #expect(hours.contains(at(20, 17, 59), calendar: calendar))
        #expect(!hours.contains(at(20, 18, 0), calendar: calendar))
        #expect(!hours.contains(at(21, 11), calendar: calendar), "Saturday is not a working day")
        #expect(!hours.contains(at(22, 11), calendar: calendar), "nor Sunday")
    }

    @Test("The next start: later today, tomorrow, or after the weekend")
    func nextStart() {
        let hours = WorkingHours.usual
        #expect(hours.nextStart(after: at(16, 7), calendar: calendar) == at(16, 9))
        #expect(hours.nextStart(after: at(16, 9), calendar: calendar) == at(17, 9), "strictly after now")
        #expect(hours.nextStart(after: at(16, 19), calendar: calendar) == at(17, 9))
        #expect(hours.nextStart(after: at(20, 18, 30), calendar: calendar) == at(23, 9), "Friday evening: Monday")
        // The year's end: Thursday 31 December 2026 in the evening, then Friday 1 January.
        #expect(hours.nextStart(after: at(31, 20, month: 12), calendar: calendar) == at(1, 9, month: 1, year: 2027))
    }

    @Test("A night shift belongs to the day it starts on")
    func overnight() {
        // Friday only, 22:00 to 06:00.
        let hours = WorkingHours(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 6), weekdays: [6])
        #expect(!hours.contains(at(20, 21, 59), calendar: calendar))
        #expect(hours.contains(at(20, 23), calendar: calendar), "Friday night")
        #expect(hours.contains(at(21, 3), calendar: calendar), "and the small hours of Saturday")
        #expect(!hours.contains(at(21, 6), calendar: calendar))
        #expect(!hours.contains(at(21, 23), calendar: calendar), "Saturday night was not chosen")
        #expect(!hours.contains(at(20, 3), calendar: calendar), "nor the small hours of Friday")
        #expect(hours.nextStart(after: at(21, 7), calendar: calendar) == at(27, 22))
    }

    @Test("The same time twice is the 24 hours from it; no day at all never begins")
    func edges() {
        let wholeDay = WorkingHours(start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 8), weekdays: [2])
        #expect(!wholeDay.contains(at(16, 7, 59), calendar: calendar))
        #expect(wholeDay.contains(at(16, 8), calendar: calendar))
        #expect(wholeDay.contains(at(17, 7, 59), calendar: calendar))
        #expect(!wholeDay.contains(at(17, 8), calendar: calendar))
        let never = WorkingHours(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 18), weekdays: [])
        #expect(!never.contains(at(16, 10), calendar: calendar))
        #expect(never.nextStart(after: at(16, 10), calendar: calendar) == nil)
    }

    @Test("The night the clocks change: the hours still start at nine")
    func clockChange() {
        // Sunday 28 March 2027, 02:00 becomes 03:00 in Paris.
        let hours = WorkingHours(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 18), weekdays: [1, 2])
        #expect(hours.nextStart(after: at(27, 20, month: 3, year: 2027), calendar: calendar) == at(28, 9, month: 3, year: 2027))
        #expect(hours.contains(at(28, 9, month: 3, year: 2027), calendar: calendar))
    }

    @Test("The gate is quiet outside the hours, says why, and a chosen Quiet is said first")
    func gate() {
        var gate = BannerGate(hours: .usual)
        gate.calendar = calendar
        // Monday at ten: every kind may show.
        for kind in BannerGate.Kind.allCases { #expect(gate.mayShow(kind, now: at(16, 10))) }
        #expect(gate.quietReason(at: at(16, 10)) == nil)
        // Monday at seven in the evening: none, until Tuesday at nine.
        for kind in BannerGate.Kind.allCases { #expect(!gate.mayShow(kind, now: at(16, 19))) }
        #expect(gate.quietReason(at: at(16, 19)) == .outsideHours(until: at(17, 9)))
        #expect(gate.isQuiet(at: at(16, 19)))
        // Quiet chosen inside the hours: that is the reason, and it ends by itself.
        gate.quiet(until: at(16, 11))
        #expect(gate.quietReason(at: at(16, 10, 30)) == .chosen(until: at(16, 11)))
        #expect(gate.quietReason(at: at(16, 11)) == nil)
        // No hours asked for: the gate is as it always was.
        let plain = BannerGate()
        #expect(plain.mayShow(.blink, now: at(21, 23)) && plain.quietReason(at: at(21, 23)) == nil)
    }
}
