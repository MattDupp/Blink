import Foundation
import Testing
@testable import BlinkCore

/// "What is due now" is a pure function of the routine, the record, the clock and the
/// calendar. So every awkward day can be played here in a few lines: midnight, a flight,
/// daylight saving, a Mac that slept through a time.
@Suite("Routines: what is due, and when to say so")
struct RoutineTests {

    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private let paris = RoutineTests.calendar("Europe/Paris")
    private let newYork = RoutineTests.calendar("America/New_York")

    /// A moment on the wall clock of `calendar`. The default day is Friday 20 November 2026.
    private func at(_ hour: Int, _ minute: Int = 0, second: Int = 0, day: Int = 20, month: Int = 11,
                    year: Int = 2026, in calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? paris
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute,
                                                  second: second))!
    }

    /// The built-in routine, switched on, with its times at 08:00, 13:00 and 17:00.
    private func drops(_ times: [(Int, Int)] = [(8, 0), (13, 0), (17, 0)], weekdays: Set<Int>? = nil,
                       onSince: Date? = nil) -> Routine {
        var routine = Routine.eyeDrops
        routine.schedule = .timesOfDay(times: times.map { TimeOfDay(hour: $0.0, minute: $0.1) }, weekdays: weekdays)
        routine.isOn = true
        routine.onSince = onSince
        return routine
    }

    private func statuses(_ routine: Routine, _ record: [RoutineEvent] = [], now: Date,
                          calendar: Calendar? = nil) -> [RoutineSlot.Status] {
        RoutineDay(routine: routine, record: record, now: now, calendar: calendar ?? paris).slots.map(\.status)
    }

    private func event(_ action: RoutineEvent.Action, _ slot: String, at date: Date, until: Date? = nil) -> RoutineEvent {
        RoutineEvent(at: date, routine: Routine.eyeDrops.id, slot: slot, action: action, until: until)
    }

    // MARK: A plain day

    @Test("A time is due from its minute until the routine's next time")
    func plainDay() {
        #expect(statuses(drops(), now: at(7, 59, second: 59)) == [.upcoming, .upcoming, .upcoming])
        #expect(statuses(drops(), now: at(8)) == [.due, .upcoming, .upcoming])
        #expect(statuses(drops(), now: at(12, 59, second: 59)) == [.due, .upcoming, .upcoming])

        let day = RoutineDay(routine: drops(), record: [], now: at(9, 30), calendar: paris)
        #expect(day.due?.key == "2026-11-20T08:00")
        #expect(day.next?.key == "2026-11-20T13:00")
        #expect(day.due?.end == at(13))
    }

    @Test("A time whose next time has come is dropped: reminders never pile up")
    func neverPiledUp() {
        // The Mac slept from 07:50 to 13:10, or the app was started at 13:10.
        let day = RoutineDay(routine: drops(), record: [], now: at(13, 10), calendar: paris)
        #expect(day.slots.map(\.status) == [.missed, .due, .upcoming])
        #expect(day.slots.filter { $0.status == .due }.count == 1)
    }

    @Test("Asleep at the time, or started after it: still due while it is the current one")
    func lateStart() {
        #expect(statuses(drops(), now: at(9, 30)) == [.due, .upcoming, .upcoming])
        #expect(statuses(drops(), now: at(23, 59, second: 59)) == [.missed, .missed, .due])
    }

    @Test("Done wins, and stays done")
    func done() {
        let record = [event(.shown, "2026-11-20T08:00", at: at(8, 0, second: 20)),
                      event(.done, "2026-11-20T08:00", at: at(8, 3))]
        #expect(statuses(drops(), record, now: at(8, 4)) == [.done(at: at(8, 3)), .upcoming, .upcoming])
        #expect(statuses(drops(), record, now: at(18)) == [.done(at: at(8, 3)), .missed, .due])
    }

    @Test("Later hides a time until the chosen moment, but not past its end")
    func later() {
        let record = [event(.later, "2026-11-20T08:00", at: at(8, 1), until: at(8, 16))]
        #expect(statuses(drops(), record, now: at(8, 15, second: 59)).first == .later(until: at(8, 16)))
        #expect(statuses(drops(), record, now: at(8, 16)).first == .due)
        #expect(RoutineDay(routine: drops(), record: record, now: at(8, 10), calendar: paris).putOff?.key == "2026-11-20T08:00")

        // Put off at 12:55 until 13:10: at 13:00 the next time takes over.
        let late = [event(.later, "2026-11-20T08:00", at: at(12, 55), until: at(13, 10))]
        #expect(statuses(drops(), late, now: at(13, 5)) == [.missed, .due, .upcoming])
    }

    @Test("Two times five minutes apart: the first gives way to the second")
    func closeTogether() {
        let routine = drops([(8, 0), (8, 5)])
        #expect(statuses(routine, now: at(8, 4)) == [.due, .upcoming])
        #expect(statuses(routine, now: at(8, 6)) == [.missed, .due])
    }

    @Test("Times are put in order and doubles are dropped")
    func orderedTimes() {
        let routine = drops([(17, 0), (8, 0), (8, 0)])
        #expect(RoutineDay(routine: routine, record: [], now: at(7), calendar: paris).slots.map(\.time.text) == ["08:00", "17:00"])
    }

    // MARK: Midnight

    @Test("At midnight the day starts again, and what was left is written as missed, once")
    func midnight() {
        var record = [event(.done, "2026-11-20T08:00", at: at(8, 3))]
        #expect(statuses(drops(), record, now: at(23, 59, second: 59)) == [.done(at: at(8, 3)), .missed, .due])

        let afterMidnight = at(0, 0, day: 21)
        #expect(statuses(drops(), record, now: afterMidnight) == [.upcoming, .upcoming, .upcoming])

        let misses = RoutineDay.unrecordedMisses(routines: [drops()], record: record, now: afterMidnight, calendar: paris)
        #expect(misses.map(\.slot) == ["2026-11-20T13:00", "2026-11-20T17:00"])
        #expect(misses.last?.at == afterMidnight)        // dropped at midnight

        record += misses
        #expect(RoutineDay.unrecordedMisses(routines: [drops()], record: record, now: afterMidnight, calendar: paris).isEmpty)
    }

    // MARK: The clock moves

    @Test("Done at 08:00, then a flight west: the same date's 08:00 does not come twice")
    func flightWest() {
        let record = [event(.done, "2026-11-20T08:00", at: at(8, 3))]
        // 08:00 in New York on the same date is six hours later.
        let again = at(8, 0, in: newYork)
        #expect(again.timeIntervalSince(at(8)) == 6 * 3600)
        #expect(statuses(drops(), record, now: again, calendar: newYork).first == .done(at: at(8, 3)))
        // The moments follow the new clock: 13:00 there, not 13:00 in Paris.
        let day = RoutineDay(routine: drops(), record: record, now: again, calendar: newYork)
        #expect(day.next?.due == at(13, 0, in: newYork))
    }

    @Test("A flight east past midnight starts the new date's times")
    func flightEast() {
        let tokyo = Self.calendar("Asia/Tokyo")
        let record = [event(.done, "2026-11-20T17:00", at: at(17, 5))]
        // 17:30 in Paris is 01:30 the next day in Tokyo.
        let day = RoutineDay(routine: drops(), record: record, now: at(17, 30), calendar: tokyo)
        #expect(day.slots.map(\.key) == ["2026-11-21T08:00", "2026-11-21T13:00", "2026-11-21T17:00"])
        #expect(day.slots.map(\.status) == [.upcoming, .upcoming, .upcoming])
    }

    @Test("A time that daylight saving skips falls due at the next minute that exists")
    func clocksGoForward() {
        // In Paris, on 28 March 2027, 02:00 becomes 03:00: 02:30 does not exist.
        let routine = drops([(2, 30)])
        let three = at(3, 0, day: 28, month: 3, year: 2027)
        let day = RoutineDay(routine: routine, record: [], now: three, calendar: paris)
        #expect(day.slots.count == 1)
        #expect(day.slots.first?.due == three)
        #expect(day.slots.first?.status == .due)
        #expect(day.slots.first?.key == "2027-03-28T02:30")

        // Two skipped times land on the same minute: one reminder, not two.
        let both = RoutineDay(routine: drops([(2, 15), (2, 45)]), record: [], now: three, calendar: paris)
        #expect(both.slots.map(\.key) == ["2027-03-28T02:45"])
    }

    @Test("A time that happens twice when the clocks go back falls due once")
    func clocksGoBack() {
        // In Paris, on 25 October 2026, 03:00 becomes 02:00: 02:30 happens twice.
        let routine = drops([(2, 30)])
        let first = at(2, 30, day: 25, month: 10)
        let second = first.addingTimeInterval(3600)
        #expect(paris.component(.minute, from: second) == 30 && paris.component(.hour, from: second) == 2)

        let day = RoutineDay(routine: routine, record: [], now: first, calendar: paris)
        #expect(day.slots.count == 1 && day.slots.first?.status == .due)
        let record = [event(.done, "2026-10-25T02:30", at: first.addingTimeInterval(60))]
        #expect(statuses(routine, record, now: second, calendar: paris) == [.done(at: first.addingTimeInterval(60))])
    }

    // MARK: Which days, and since when

    @Test("Chosen weekdays: no times on the other days")
    func weekdays() {
        let routine = drops(weekdays: [2, 4, 6])        // Monday, Wednesday, Friday
        #expect(statuses(routine, now: at(9, 0, day: 20)).count == 3)      // a Friday
        #expect(statuses(routine, now: at(9, 0, day: 21)).isEmpty)         // a Saturday
    }

    @Test("Switched off: nothing is planned")
    func switchedOff() {
        var routine = drops()
        routine.isOn = false
        #expect(statuses(routine, now: at(9)).isEmpty)
    }

    @Test("Switched on at 13:10: the times already past are not asked for")
    func switchedOnLate() {
        let routine = drops(onSince: at(13, 10))
        #expect(statuses(routine, now: at(13, 10)) == [.notAsked, .notAsked, .upcoming])
        #expect(statuses(routine, now: at(17)) == [.notAsked, .notAsked, .due])
        // The next day everything counts again.
        #expect(statuses(routine, now: at(8, 0, day: 21)) == [.due, .upcoming, .upcoming])
        #expect(RoutineDay.unrecordedMisses(routines: [routine], record: [], now: at(18), calendar: paris).isEmpty)
    }

    @Test("The two kinds without a screen yet plan nothing, and do not break anything")
    func otherKinds() {
        for schedule in [RoutineSchedule.timesPerWeek(count: 3), .everyMinutesAtScreen(minutes: 45)] {
            let routine = Routine(id: "other", name: "Other", symbol: "star", schedule: schedule, isOn: true)
            #expect(RoutineDay(routine: routine, record: [], now: at(9), calendar: paris).slots.isEmpty)
            #expect(routine.times.isEmpty)
        }
    }

    // MARK: When to show a banner

    private func slot(_ record: [RoutineEvent], now: Date) -> RoutineSlot {
        RoutineDay(routine: drops(), record: record, now: now, calendar: paris).slots[0]
    }

    @Test("A banner waits for somebody to be at the screen")
    func waitsForYou() {
        let policy = RoutinePolicy()
        #expect(!policy.bannerDue(for: slot([], now: at(8)), record: [], now: at(8), someoneThere: false))
        #expect(policy.bannerDue(for: slot([], now: at(8, 40)), record: [], now: at(8, 40), someoneThere: true))
        #expect(!policy.bannerDue(for: slot([], now: at(7)), record: [], now: at(7), someoneThere: true))
    }

    @Test("One banner, one repeat ten minutes later, then no more")
    func oneRepeat() {
        let policy = RoutinePolicy()
        var record = [event(.shown, "2026-11-20T08:00", at: at(8))]
        #expect(!policy.bannerDue(for: slot(record, now: at(8, 9)), record: record, now: at(8, 9), someoneThere: true))
        #expect(policy.bannerDue(for: slot(record, now: at(8, 10)), record: record, now: at(8, 10), someoneThere: true))

        record.append(event(.shown, "2026-11-20T08:00", at: at(8, 10)))
        #expect(!policy.bannerDue(for: slot(record, now: at(11)), record: record, now: at(11), someoneThere: true))
    }

    @Test("After Later the banner comes back at the chosen moment; after Done, never")
    func afterLaterAndDone() {
        let policy = RoutinePolicy()
        #expect(policy.later(from: at(8, 1)) == at(8, 16))
        var record = [event(.shown, "2026-11-20T08:00", at: at(8)), event(.shown, "2026-11-20T08:00", at: at(8, 10)),
                      event(.later, "2026-11-20T08:00", at: at(8, 11), until: at(8, 26))]
        #expect(!policy.bannerDue(for: slot(record, now: at(8, 20)), record: record, now: at(8, 20), someoneThere: true))
        #expect(policy.bannerDue(for: slot(record, now: at(8, 26)), record: record, now: at(8, 26), someoneThere: true))

        record.append(event(.done, "2026-11-20T08:00", at: at(8, 27)))
        #expect(!policy.bannerDue(for: slot(record, now: at(8, 40)), record: record, now: at(8, 40), someoneThere: true))
    }

    // MARK: On disk

    @Test("The record is read back as it was written; a damaged line is skipped")
    func recordOnDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("routine-test-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = RoutineStore(file: file)
        let written = [event(.shown, "2026-11-20T08:00", at: at(8)),
                       event(.later, "2026-11-20T08:00", at: at(8, 1), until: at(8, 16)),
                       event(.done, "2026-11-20T08:00", at: at(8, 20))]
        for event in written { #expect(store.append(event)) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not a line\n".utf8))
        try handle.close()

        #expect(store.load(since: at(0)) == written)
        #expect(store.load(since: at(8, 10)) == [written[2]])
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("at,routine,slot,action,until\n"))
        #expect(store.erase())
        #expect(store.load(since: at(0)).isEmpty)
        #expect(RoutineStore.safe("a,b\nc") == "a_b_c")
    }

    @Test("A routine of each kind survives being stored, and a new built-in one is added to old settings")
    func stored() throws {
        let routines = [drops(weekdays: [2, 6], onSince: at(7)),
                        Routine(id: "weekly", name: "Weekly", symbol: "star", schedule: .timesPerWeek(count: 3)),
                        Routine(id: "screen", name: "Screen", symbol: "clock", schedule: .everyMinutesAtScreen(minutes: 45))]
        let data = try JSONEncoder().encode(routines)
        #expect(try JSONDecoder().decode([Routine].self, from: data) == routines)

        #expect(Routine.merged(stored: []) == Routine.builtIn)
        #expect(Routine.merged(stored: [routines[1]]).map(\.id) == ["weekly", "eye-drops"])
        #expect(Routine.merged(stored: [routines[0]]) == [routines[0]])      // your own times are kept
        #expect(!Routine.eyeDrops.isOn)
    }
}
