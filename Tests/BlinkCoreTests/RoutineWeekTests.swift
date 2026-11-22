import Foundation
import Testing
@testable import BlinkCore

/// "Three times a week" is a pure function of the routine, the record, the clock and the
/// calendar, like the day. Every awkward week is played here: a missed day, a count
/// reached early, a week that can no longer be completed, the week turning over.
///
/// The week of these tests: Monday 16 to Sunday 22 November 2026. The routine prefers
/// Monday, Wednesday and Friday at 17:00.
@Suite("Routines: so many times a week")
struct RoutineWeekTests {

    private static func calendar(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday       // 2: the week starts on Monday
        return calendar
    }

    private let paris = RoutineWeekTests.calendar("Europe/Paris")
    private let id = Routine.heatedMask.id

    /// A moment of November 2026 on the wall clock of `calendar`.
    private func at(day: Int, _ hour: Int = 12, _ minute: Int = 0, in calendar: Calendar? = nil) -> Date {
        (calendar ?? paris).date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// The built-in routine, switched on before the week began.
    private func mask(count: Int = 3, weekdays: Set<Int> = [2, 4, 6], onSince: Date? = nil) -> Routine {
        var routine = Routine.heatedMask
        routine.schedule = .timesPerWeek(count: count, weekdays: weekdays, time: TimeOfDay(hour: 17))
        routine.isOn = true
        routine.onSince = onSince ?? at(day: 1)
        return routine
    }

    /// Done on that day of November, at that hour.
    private func done(_ day: Int, _ hour: Int = 18) -> RoutineEvent {
        RoutineEvent(at: at(day: day, hour), routine: id, slot: String(format: "2026-11-%02d", day), action: .done)
    }

    private func week(_ routine: Routine? = nil, _ record: [RoutineEvent] = [], day: Int,
                      calendar: Calendar? = nil) -> RoutineWeek {
        RoutineWeek(routine: routine ?? mask(), record: record, on: at(day: day, in: calendar), calendar: calendar ?? paris)!
    }

    /// The days of November that asked, from the start of the week up to `day` included.
    /// (For the days after it the week can only say what would ask if nothing more is done.)
    private func asking(_ record: [RoutineEvent] = [], upTo day: Int, routine: Routine? = nil) -> [Int] {
        let week = week(routine, record, day: day)
        return week.days.prefix(week.todayIndex + 1).filter(\.asks).map { paris.component(.day, from: $0.start) }
    }

    private func status(_ record: [RoutineEvent] = [], day: Int, _ hour: Int, routine: Routine? = nil) -> RoutineSlot.Status? {
        RoutineDay(routine: routine ?? mask(), record: record, now: at(day: day, hour), calendar: paris).slots.first?.status
    }

    // MARK: A plain week

    @Test("With nothing done yet, the preferred days ask, at the chosen time")
    func plainWeek() {
        let week = week(day: 16)
        #expect(week.days.count == 7)
        #expect(week.target == 3 && week.done == 0 && !week.isReached)
        #expect(week.days.first?.key == "2026-11-16" && week.days.last?.key == "2026-11-22")
        // Monday asks. Seen from Monday, with nothing done, every later day would ask too:
        // each is either preferred or needed to catch up.
        #expect(week.today.asks)

        #expect(status(day: 16, 16) == .upcoming)
        #expect(status(day: 16, 17) == .due)
        #expect(status(day: 16, 23) == .due)                    // it waits until midnight
        let slot = RoutineDay(routine: mask(), record: [], now: at(day: 16, 17), calendar: paris).slots.first
        #expect(slot?.key == "2026-11-16")
        #expect(slot?.end == at(day: 17, 0))
    }

    @Test("Kept on its days: Monday, Wednesday, Friday ask, the other days do not")
    func keptWeek() {
        #expect(status([done(16)], day: 17, 18) == nil)                         // Tuesday: on track
        #expect(status([done(16)], day: 18, 18) == .due)                        // Wednesday
        #expect(status([done(16), done(18)], day: 19, 18) == nil)               // Thursday: on track
        #expect(status([done(16), done(18)], day: 20, 18) == .due)              // Friday
        #expect(asking([done(16), done(18), done(20)], upTo: 22) == [16, 18, 20])
    }

    // MARK: The count

    @Test("Once the count is reached, nothing asks until the next week")
    func reached() {
        let record = [done(16), done(18), done(20)]
        let week = week(nil, record, day: 21)
        #expect(week.done == 3 && week.isReached)
        #expect(week.nextAsk == nil)
        #expect(status(record, day: 21, 18) == nil)
        #expect(status(record, day: 22, 18) == nil)
    }

    @Test("Done early counts: on a day that did not ask, or before the time")
    func doneEarly() {
        // Tuesday did not ask. Done on Tuesday all the same.
        let record = [done(16), done(17, 9)]
        #expect(week(nil, record, day: 17).done == 2)
        // Wednesday still asks (one is left), and once it is done Friday stays quiet.
        #expect(status(record, day: 18, 18) == .due)
        #expect(status(record + [done(18)], day: 20, 18) == nil)

        // Before the time on a day that asks: the day's slot is done, not waiting at 17:00.
        let morning = RoutineEvent(at: at(day: 16, 9), routine: id, slot: "2026-11-16", action: .done)
        #expect(status([morning], day: 16, 17) == .done(at: at(day: 16, 9)))
    }

    @Test("Two on one day count as two, and the day does not ask again")
    func twoOnOneDay() {
        let record = [done(16, 8), done(16, 20)]
        #expect(week(nil, record, day: 16).today.done == 2)
        #expect(week(nil, record, day: 16).done == 2)
        // One left: Wednesday asks, and with it done, Friday does not.
        #expect(asking(record, upTo: 18) == [16, 18])
        #expect(asking(record + [done(18)], upTo: 22) == [16, 18])
    }

    @Test("A done pressed by mistake can be taken back")
    func undone() {
        let back = RoutineEvent(at: at(day: 16, 19), routine: id, slot: "2026-11-16", action: .undone)
        #expect(week(nil, [done(16)], day: 16).done == 1)
        #expect(week(nil, [done(16), back], day: 16).done == 0)
        #expect(status([done(16), back], day: 16, 20) == .due)
        // Taking back with nothing to take back changes nothing.
        #expect(week(nil, [back], day: 16).done == 0)
        // Done, taken back, done again: one.
        #expect(week(nil, [done(16), back, done(16, 21)], day: 16).done == 1)
    }

    // MARK: Behind

    @Test("A missed day is carried over: miss Wednesday, and Thursday asks")
    func missedDayCarriedOver() {
        // Monday done, Wednesday not. Thursday: two to do, one preferred day left.
        #expect(status([done(16)], day: 19, 16) == .upcoming)
        #expect(status([done(16)], day: 19, 18) == .due)
        // Done on Thursday: Friday asks for the third, then the weekend is quiet.
        #expect(status([done(16), done(19)], day: 20, 18) == .due)
        #expect(status([done(16), done(19), done(20)], day: 21, 18) == nil)
        // Not done on Thursday either: Friday, Saturday and Sunday each ask, once.
        #expect(asking([done(16)], upTo: 22) == [16, 18, 19, 20, 21, 22])
    }

    @Test("A day never asks twice, and yesterday's unanswered ask is dropped at midnight")
    func oneAskADay() {
        let day = RoutineDay(routine: mask(), record: [], now: at(day: 19, 18), calendar: paris)
        #expect(day.slots.count == 1)
        // Wednesday seen from Thursday: it was missed, not still waiting.
        let wednesday = RoutineDay.slots(of: mask(), on: at(day: 18), record: [], now: at(day: 19, 9), calendar: paris)
        #expect(wednesday.map(\.status) == [.missed])
        let misses = RoutineDay.unrecordedMisses(routines: [mask()], record: [done(16)], now: at(day: 19, 9), calendar: paris)
        #expect(misses.map(\.slot) == ["2026-11-18"])
    }

    @Test("A week that can no longer be completed still asks once a day, and no more")
    func outOfReach() {
        // Sunday, nothing done all week: three to do, one day left.
        let week = week(day: 22)
        #expect(week.done == 0 && week.today.asks)
        let sunday = RoutineDay(routine: mask(), record: [], now: at(day: 22, 18), calendar: paris)
        #expect(sunday.slots.map(\.status) == [.due])
        // Done on Sunday: "1 of 3", and the day is settled.
        #expect(status([done(22)], day: 22, 20) == .done(at: at(day: 22, 18)))
        #expect(RoutineWeek(routine: mask(), record: [done(22)], on: at(day: 22, 20), calendar: paris)?.done == 1)
    }

    // MARK: The week turning over

    @Test("A new week starts at zero: nothing is owed from the last one")
    func weekTurnsOver() {
        // Last week: one of three. Monday 23 is a plain Monday.
        let record = [done(16)]
        let next = week(nil, record, day: 23)
        #expect(next.done == 0)
        #expect(next.days.first?.key == "2026-11-23")
        #expect(status(record, day: 23, 18) == .due)
        // With Monday done, Tuesday is quiet: last week's two missing ones are not owed.
        #expect(status(record + [done(23)], day: 24, 18) == nil)
        #expect(asking(record + [done(23), done(25), done(27)], upTo: 29) == [23, 25, 27])
    }

    @Test("Sunday night and Monday morning are two different weeks")
    func midnightBetweenWeeks() {
        let full = [done(16), done(18), done(20)]
        #expect(week(nil, full, day: 22).isReached)
        #expect(!week(nil, full, day: 23).isReached)
        #expect(status(full, day: 22, 23) == nil)
        #expect(status(full, day: 23, 17) == .due)
    }

    @Test("The week starts where the calendar says: Sunday for some, Monday for others")
    func whereTheWeekStarts() {
        let sundayFirst = RoutineWeekTests.calendar("Europe/Paris", firstWeekday: 1)
        let week = RoutineWeek(routine: mask(), record: [done(16)], on: at(day: 16), calendar: sundayFirst)!
        #expect(week.days.first?.key == "2026-11-15" && week.days.last?.key == "2026-11-21")
        // Sunday 22 then belongs to the next week: what was done on Monday 16 is not in it.
        #expect(RoutineWeek(routine: mask(), record: [done(16)], on: at(day: 22), calendar: sundayFirst)?.done == 0)
        #expect(RoutineWeek(routine: mask(), record: [done(16)], on: at(day: 22), calendar: paris)?.done == 1)
    }

    // MARK: The clock moved, the Mac asleep

    @Test("A flight does not move what was done to another day or week")
    func timeZone() {
        // Done on Sunday 22 at 23:30 in Paris. In New York that moment is still Sunday,
        // 17:30; in Tokyo it is already Monday 23. The record says "2026-11-22" everywhere.
        let event = RoutineEvent(at: at(day: 22, 23, 30), routine: id, slot: "2026-11-22", action: .done)
        let tokyo = RoutineWeekTests.calendar("Asia/Tokyo")
        let inTokyo = RoutineWeek(routine: mask(), record: [event], on: at(day: 23, 9, in: tokyo), calendar: tokyo)!
        #expect(inTokyo.days.first?.key == "2026-11-23")
        #expect(inTokyo.done == 0)                                 // Monday's week: not counted twice
        let lastWeek = RoutineWeek(routine: mask(), record: [event], on: at(day: 22, 12, in: tokyo), calendar: tokyo)!
        #expect(lastWeek.done == 1)
    }

    @Test("A Mac asleep for two days: one reminder on waking, not three")
    func asleepTwoDays() {
        // Done on Monday, then asleep from Tuesday to Friday morning.
        let day = RoutineDay(routine: mask(), record: [done(16)], now: at(day: 20, 9), calendar: paris)
        #expect(day.slots.map(\.status) == [.upcoming])            // Friday's own ask, at 17:00
        #expect(day.week?.done == 1)
        // Only yesterday is written as missed; older days leave no line (the app was not running).
        let misses = RoutineDay.unrecordedMisses(routines: [mask()], record: [done(16)], now: at(day: 20, 9), calendar: paris)
        #expect(misses.map(\.slot) == ["2026-11-19"])
    }

    @Test("The clocks change during the week: still seven days, still 17:00")
    func daylightSaving() {
        // Europe goes back to winter time on Sunday 25 October 2026: that day lasts 25 hours.
        var routine = mask()
        routine.onSince = paris.date(from: DateComponents(year: 2026, month: 10, day: 1))
        let friday = paris.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        let week = RoutineWeek(routine: routine, record: [], on: friday, calendar: paris)!
        #expect(week.days.map(\.key) == (19...25).map { "2026-10-\($0)" })
        let sunday = paris.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 18))!
        let slot = RoutineDay(routine: routine, record: [], now: sunday, calendar: paris).slots.first
        #expect(slot.map { paris.component(.hour, from: $0.due) } == 17)
    }

    // MARK: Switching on, and other settings

    @Test("Switched on part of the way through a week: preferred days only, no catching up")
    func firstWeek() {
        // Switched on Thursday at 10:00. Thursday does not ask, Friday does, the weekend does not.
        let routine = mask(onSince: at(day: 19, 10))
        #expect(asking(upTo: 22, routine: routine) == [20])
        #expect(status(day: 19, 18, routine: routine) == nil)
        #expect(status(day: 20, 18, routine: routine) == .due)
        // The week after is an ordinary one.
        #expect(RoutineDay(routine: routine, record: [], now: at(day: 24, 18), calendar: paris).slots.map(\.status) == [.due])
    }

    @Test("Switched on after the time on a preferred day: not asked for that day")
    func switchedOnAfterTheTime() {
        let routine = mask(onSince: at(day: 20, 17, 30))
        #expect(status(day: 20, 18, routine: routine) == .notAsked)
    }

    @Test("Switched off: no slots and no week")
    func switchedOff() {
        var routine = mask()
        routine.isOn = false
        let day = RoutineDay(routine: routine, record: [], now: at(day: 16, 18), calendar: paris)
        #expect(day.slots.isEmpty && day.week == nil)
    }

    @Test("More times than preferred days: the other days make up the count")
    func fewPreferredDays() {
        // Three times a week, Friday preferred. Monday and Tuesday must ask, or three cannot be reached.
        let routine = mask(weekdays: [6])
        #expect(asking(upTo: 17, routine: routine) == [16, 17])
        // Both done: Wednesday and Thursday are quiet, Friday asks.
        #expect(asking([done(16), done(17)], upTo: 20, routine: routine) == [16, 17, 20])
    }

    @Test("Any routine can be counted by the week, not only the built-in one")
    func anyRoutine() {
        let own = Routine(id: "own", name: "Something of mine", symbol: "star",
                          schedule: .timesPerWeek(count: 1, weekdays: [3], time: TimeOfDay(hour: 9)), isOn: true)
        let tuesday = RoutineDay(routine: own, record: [], now: at(day: 17, 10), calendar: paris)
        #expect(tuesday.slots.map(\.status) == [.due])
        #expect(tuesday.week?.target == 1)
    }

    @Test("The built-in routine: off, three times a week, with a timer")
    func builtIn() {
        #expect(Routine.builtIn.contains(Routine.heatedMask))
        #expect(!Routine.heatedMask.isOn)
        #expect(Routine.heatedMask.sessionMinutes != nil)
        // Settings saved before it existed gain it, switched off.
        #expect(Routine.merged(stored: [.eyeDrops]).map(\.id) == ["eye-drops", "heated-mask"])
        // And it survives being saved and read back.
        let data = try? JSONEncoder().encode([Routine.heatedMask])
        #expect(data.flatMap { try? JSONDecoder().decode([Routine].self, from: $0) } == [Routine.heatedMask])
    }

    @Test("Settings saved by the version before read back: no timer, nothing lost")
    func olderSettings() throws {
        // What the version before wrote for the eye drops: no `sessionMinutes` at all.
        let old = #"[{"id":"eye-drops","name":"Eye drops","symbol":"drop","isOn":true,"#
            + #""schedule":{"timesOfDay":{"times":[{"hour":8,"minute":0}]}}}]"#
        let routines = try JSONDecoder().decode([Routine].self, from: Data(old.utf8))
        #expect(routines.first?.isOn == true && routines.first?.sessionMinutes == nil)
        #expect(routines.first?.times == [TimeOfDay(hour: 8)])
    }

    // MARK: The timer

    @Test("A session knows its end, so sleep cannot make it wrong")
    func session() {
        let start = at(day: 20, 17)
        let session = RoutineSession(routine: mask(), start: start)!
        #expect(session.end == at(day: 20, 17, 10))
        #expect(session.clock(at: start) == "10:00")
        #expect(session.clock(at: start.addingTimeInterval(175)) == "7:05")
        #expect(session.progress(at: start.addingTimeInterval(300)) == 0.5)
        #expect(!session.isOver(at: start.addingTimeInterval(599)))
        #expect(session.isOver(at: at(day: 20, 17, 10)))
        // Asked long after (the Mac slept): over, nothing left, never negative.
        #expect(session.remaining(at: at(day: 21)) == 0 && session.progress(at: at(day: 21)) == 1)

        var plain = mask()
        plain.sessionMinutes = nil
        #expect(RoutineSession(routine: plain, start: start) == nil)
    }
}
