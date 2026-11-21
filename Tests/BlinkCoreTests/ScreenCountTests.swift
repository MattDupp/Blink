import Foundation
import Testing
@testable import BlinkCore

/// "Every 60 minutes at the screen", played on timelines written by hand: who was there,
/// minute by minute. No camera and no clock: `ScreenCount` is told both.
@Suite("Routines at the screen: what the minutes count")
struct ScreenCountTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    /// A moment of Friday 20 November 2026, on the wall clock of Paris.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// A timeline: stretches of minutes, each with somebody there or not, looked at every
    /// 20 seconds as the app does. Remembers when each occasion opened.
    private struct Timeline {
        var count = ScreenCount()
        var now: Date
        var opened: [ScreenCount.Occasion] = []
        let every: Int
        let calendar: Calendar

        mutating func pass(_ minutes: Int, present: Bool, holding: Bool = false) {
            for _ in 0..<(minutes * 3) {
                now += 20
                count.advance(to: now, present: present, holding: holding, minutes: every, calendar: calendar)
                if let open = count.open, open != opened.last { opened.append(open) }
            }
        }
    }

    private func timeline(from start: Date, every: Int = 60) -> Timeline {
        var timeline = Timeline(now: start, every: every, calendar: calendar)
        timeline.count.advance(to: start, present: true, minutes: every, calendar: calendar)
        return timeline
    }

    private var water: Routine {
        Routine(id: "user-water", name: "Drink water", symbol: "cup.and.saucer",
                schedule: .everyMinutesAtScreen(minutes: 60), isOn: true)
    }

    // MARK: What is counted

    @Test("An hour at the screen opens one occasion, named by the day and its number")
    func anHour() {
        var day = timeline(from: at(9))
        day.pass(59, present: true)
        #expect(day.opened.isEmpty && day.count.minutesLeft(of: 60) == 1)
        day.pass(1, present: true)
        #expect(day.opened.map(\.key) == ["2026-11-20#1"])
        #expect(day.opened.first?.due == at(10))
        #expect(day.count.seconds == 0)          // the count starts again at once
    }

    @Test("Minutes at the screen, not on the clock: a short absence only stops the count")
    func shortAbsence() {
        var day = timeline(from: at(9))
        day.pass(40, present: true)
        day.pass(4, present: false)
        day.pass(19, present: true)
        #expect(day.opened.isEmpty)
        day.pass(1, present: true)
        #expect(day.opened.first?.due == at(10, 4))     // 60 minutes there, 64 on the clock
    }

    @Test("Five minutes away start the count again")
    func longAbsence() {
        var day = timeline(from: at(9))
        day.pass(50, present: true)
        day.pass(5, present: false)
        #expect(day.count.seconds == 0)
        day.pass(59, present: true)
        #expect(day.opened.isEmpty)
        day.pass(1, present: true)
        #expect(day.opened.first?.due == at(10, 55))
    }

    @Test("An occasion left open is closed by a long absence: nothing stale waits for you")
    func absenceClosesIt() {
        var day = timeline(from: at(9))
        day.pass(60, present: true)
        #expect(day.count.open != nil)
        day.pass(4, present: false)
        #expect(day.count.open != nil)
        day.pass(1, present: false)
        #expect(day.count.open == nil)
    }

    @Test("Left unanswered, the next one replaces it: two are never open together")
    func noPile() {
        var day = timeline(from: at(9))
        day.pass(180, present: true)
        #expect(day.opened.map(\.key) == ["2026-11-20#1", "2026-11-20#2", "2026-11-20#3"])
        #expect(day.count.open?.key == "2026-11-20#3")
    }

    @Test("Done starts the count again; nothing else you press does")
    func doneRestarts() {
        var day = timeline(from: at(9))
        day.pass(70, present: true)             // open at 10:00, ten minutes on the next
        day.count.restart()                     // Done at 10:10
        day.pass(59, present: true)
        #expect(day.opened.count == 1)
        day.pass(1, present: true)
        #expect(day.opened.last?.due == at(11, 10))
    }

    @Test("Under a routine's timer the count stands still: neither there nor away")
    func holding() {
        var day = timeline(from: at(9))
        day.pass(30, present: true)
        day.pass(10, present: false, holding: true)
        #expect(day.count.seconds == 30 * 60 && day.count.away == 0)
        day.pass(30, present: true)
        #expect(day.opened.first?.due == at(10, 10))
    }

    @Test("A Mac that slept was not at the screen, whatever the camera said last")
    func sleep() {
        var count = ScreenCount()
        count.advance(to: at(9), present: true, minutes: 60, calendar: calendar)
        count.advance(to: at(9, 0).addingTimeInterval(20), present: true, minutes: 60, calendar: calendar)
        count.advance(to: at(11), present: true, minutes: 60, calendar: calendar)     // two hours in one step
        #expect(count.seconds == 0 && count.open == nil)
    }

    @Test("A new day starts from zero, with nothing open")
    func newDay() {
        var night = timeline(from: at(22, 30))
        night.pass(70, present: true)           // open at 23:30
        #expect(night.count.open?.key == "2026-11-20#1")
        night.pass(25, present: true)           // 00:05
        #expect(night.count.open == nil && night.count.seconds == 5 * 60)
        night.pass(55, present: true)
        #expect(night.count.open?.key == "2026-11-21#1")
    }

    // MARK: The count as a routine's day

    @Test("The open occasion is the routine's one slot; the record says where it stands")
    func slot() {
        var day = timeline(from: at(9))
        day.pass(30, present: true)
        #expect(RoutineDay(routine: water, record: [], now: day.now, calendar: calendar, screen: day.count).slots.isEmpty)
        #expect(RoutineDay(routine: water, record: [], now: day.now, calendar: calendar, screen: day.count).minutesLeft == 30)
        day.pass(35, present: true)
        let key = "2026-11-20#1"
        func status(_ record: [RoutineEvent]) -> RoutineSlot.Status? {
            RoutineDay(routine: water, record: record, now: day.now, calendar: calendar, screen: day.count).slots.first?.status
        }
        #expect(status([]) == .due)
        #expect(status([RoutineEvent(at: at(10, 2), routine: water.id, slot: key, action: .later, until: at(10, 17))])
                == .later(until: at(10, 17)))
        #expect(status([RoutineEvent(at: at(10, 3), routine: water.id, slot: key, action: .done)]) == .done(at: at(10, 3)))
    }

    @Test("Switched off, or with no count yet, it asks nothing")
    func off() {
        var routine = water
        #expect(RoutineDay(routine: routine, record: [], now: at(9), calendar: calendar).slots.isEmpty)
        routine.isOn = false
        var day = timeline(from: at(9))
        day.pass(60, present: true)
        let off = RoutineDay(routine: routine, record: [], now: day.now, calendar: calendar, screen: day.count)
        #expect(off.slots.isEmpty && off.screen == nil)
    }

    // MARK: Gently

    private func shown(_ moments: [Date], routine: String = "a") -> [RoutineEvent] {
        moments.map { RoutineEvent(at: $0, routine: routine, slot: "s", action: .shown) }
    }

    @Test("Two banners are at least five minutes apart, whatever the routines")
    func gap() {
        let policy = RoutinePolicy()
        #expect(policy.mayShow(record: [], now: at(9)))
        #expect(!policy.mayShow(record: shown([at(9)]), now: at(9, 4)))
        #expect(policy.mayShow(record: shown([at(9)]), now: at(9, 5)))
    }

    @Test("No more than four banners in an hour")
    func hourlyLimit() {
        let policy = RoutinePolicy()
        let four = shown([at(9), at(9, 10), at(9, 20), at(9, 30)])
        #expect(!policy.mayShow(record: four, now: at(9, 45)))
        #expect(!policy.mayShow(record: four, now: at(9, 59)))
        #expect(policy.mayShow(record: four, now: at(10)))          // the 09:00 one is an hour old
    }

    @Test("A routine at the screen is shown once, not once more after ten minutes")
    func noRepeat() {
        let policy = RoutinePolicy()
        let slot = RoutineSlot(routine: "a", key: "s", time: TimeOfDay(hour: 9), due: at(9), end: at(23), status: .due)
        let record = shown([at(9)])
        #expect(policy.bannerDue(for: slot, record: record, now: at(9, 10), someoneThere: true))
        #expect(!policy.bannerDue(for: slot, record: record, now: at(9, 10), someoneThere: true, repeats: false))
        // After "Later", once again all the same.
        let later = record + [RoutineEvent(at: at(9, 1), routine: "a", slot: "s", action: .later, until: at(9, 16))]
        #expect(policy.bannerDue(for: slot, record: later, now: at(9, 16), someoneThere: true, repeats: false))
    }

    @Test("Due together: a time of day goes before a routine at the screen")
    func order() {
        var day = timeline(from: at(11, 50))
        day.pass(60, present: true)             // open at 12:50
        var drops = Routine.eyeDrops
        drops.isOn = true
        let now = at(13, 1)
        let days = [RoutineDay(routine: water, record: [], now: now, calendar: calendar, screen: day.count),
                    RoutineDay(routine: drops, record: [], now: now, calendar: calendar)]
        #expect(days.allSatisfy { $0.due != nil })
        #expect(RoutinePolicy().order(days).map(\.routine.id) == [drops.id, water.id])
    }

    // MARK: What is typed, and what was stored

    @Test("A typed name is kept to one short line, whatever is typed or pasted")
    func names() {
        #expect(Routine.typedName("Drink water ") == "Drink water ")       // the space before the next word stays
        #expect(Routine.typedName("  a,b\n\"c\"\t\u{0}d") == "a,b \"c\"  d")
        #expect(Routine.typedName(String(repeating: "x", count: 500)).count == Routine.nameLimit)
        var routine = water
        routine.name = "   "
        #expect(routine.title == "Reminder")
        routine.name = "Tea\r\n,now "
        #expect(routine.title == "Tea  ,now")
    }

    @Test("A routine made from a starting point: on, with an id that holds no comma")
    func made() {
        #expect(Set(RoutineTemplate.all.map(\.id)).count == RoutineTemplate.all.count)
        for template in RoutineTemplate.all {
            let routine = Routine.made(from: template, now: at(9))
            #expect(routine.isOn && routine.onSince == at(9) && !routine.isBuiltIn)
            #expect(routine.id.hasPrefix("user-") && routine.id.count == 13 && !routine.id.contains(","))
            #expect(Routine.symbols.contains(routine.symbol))
        }
        #expect(Routine.made(from: RoutineTemplate.all[0], now: at(9)).id != Routine.made(from: RoutineTemplate.all[0], now: at(9)).id)
    }

    /// The settings as the two earlier versions wrote them (commits 4484538 and 8a9a547).
    static let storedByFirst = """
        [{"id":"eye-drops","name":"Eye drops","symbol":"drop","isOn":true,"onSince":801000000,\
        "schedule":{"timesOfDay":{"times":[{"hour":8,"minute":0},{"hour":12,"minute":30}]}}}]
        """
    static let storedBySecond = """
        [{"id":"eye-drops","name":"Eye drops","symbol":"drop","isOn":false,\
        "schedule":{"timesOfDay":{"times":[{"hour":8,"minute":0}],"weekdays":[2,3,4,5,6]}}},\
        {"id":"heated-mask","name":"Heated eye mask","symbol":"eye","isOn":true,"onSince":801000000,"sessionMinutes":12,\
        "schedule":{"timesPerWeek":{"count":2,"weekdays":[3,5],"time":{"hour":18,"minute":15}}}}]
        """

    @Test("Routines stored by the two earlier versions still load, with every choice kept")
    func storedForm() throws {
        let first = try JSONDecoder().decode([Routine].self, from: Data(Self.storedByFirst.utf8))
        #expect(first.count == 1 && first[0].isOn && first[0].sessionMinutes == nil)
        #expect(first[0].times == [TimeOfDay(hour: 8), TimeOfDay(hour: 12, minute: 30)])
        #expect(first[0].onSince == Date(timeIntervalSinceReferenceDate: 801_000_000))

        let second = try JSONDecoder().decode([Routine].self, from: Data(Self.storedBySecond.utf8))
        #expect(second[0].schedule == .timesOfDay(times: [TimeOfDay(hour: 8)], weekdays: [2, 3, 4, 5, 6]))
        #expect(second[1].schedule == .timesPerWeek(count: 2, weekdays: [3, 5], time: TimeOfDay(hour: 18, minute: 15)))
        #expect(second[1].sessionMinutes == 12 && second[1].isBuiltIn)

        // And the hand-written text above really is the stored form: written again by
        // today's code, it is the same JSON, key for key.
        func tree(_ data: Data) throws -> NSArray { try JSONSerialization.jsonObject(with: data) as? NSArray ?? [] }
        let again = try JSONEncoder().encode(second)
        let written = try tree(again), before = try tree(Data(Self.storedBySecond.utf8))
        // (A set is written in no fixed order: compare the days as sets.)
        func normal(_ value: Any) -> Any {
            if let list = value as? [Int] { return list.sorted() }
            if let list = value as? [Any] { return list.map(normal) }
            if let map = value as? [String: Any] { return map.mapValues(normal) as NSDictionary }
            return value
        }
        #expect((normal(written) as? NSArray) == (normal(before) as? NSArray))
    }
}
