import Foundation
import Testing
import BlinkCore
@testable import BlinkMonitor

/// Routines the user makes, as the app runs them: adding, renaming and deleting, the
/// count of time at the screen, and the rules that keep several routines gentle.
/// A clock given by hand; no banner is really shown.
@MainActor
@Suite("Routines of your own", .serialized)
struct RoutineOwnTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    /// A moment of Friday 20 November 2026, on the wall clock of Paris.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @MainActor
    final class Desk {
        var banners: [RoutineBanner] = []
        var settled: [String] = []
        var present = true
    }

    private let suite = "local.blinkmonitor.routine-own-tests"
    private var file: URL { FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-routine-own-tests.csv") }
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    /// A controller on settings and a record of its own. `fresh` false: as after a relaunch.
    private func controller(_ desk: Desk, fresh: Bool = true, now: Date? = nil) -> RoutineController {
        if fresh {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let controller = RoutineController(defaults: defaults, store: RoutineStore(file: file), now: now ?? at(0))
        controller.calendar = calendar
        controller.someoneThere = { desk.present }
        controller.onBanner = { desk.banners.append($0) }
        controller.onSettled = { desk.settled.append($0.id) }
        return controller
    }

    private let water = RoutineTemplate.all[0]      // every 60 minutes at the screen
    private let times = RoutineTemplate.all[2]      // at 09:00

    /// Looks at the clock every 20 seconds from `start` for so many minutes, as the app
    /// does. Answers the moment it stopped at.
    @discardableResult
    private func run(_ controller: RoutineController, from start: Date, minutes: Int) -> Date {
        var now = start
        controller.tick(now: now)
        for _ in 0..<(minutes * 3) {
            now += 20
            controller.tick(now: now)
        }
        return now
    }

    // MARK: Add, rename, delete

    @Test("Added from a starting point: switched on, kept across a relaunch, beside the built-in ones")
    func add() throws {
        let desk = Desk()
        let controller = controller(desk)
        let id = try #require(controller.add(water, now: at(9)))
        #expect(controller.routines.map(\.id) == Routine.builtIn.map(\.id) + [id])
        let again = self.controller(desk, fresh: false)
        #expect(again.routines.last == controller.routines.last)
        #expect(again.routines.last?.isOn == true && again.routines.last?.screenMinutes == 60)
    }

    @Test("No more than eight routines of your own")
    func mostOwn() {
        let controller = controller(Desk())
        for _ in 0..<RoutineController.mostOwn { #expect(controller.add(times, now: at(9)) != nil) }
        #expect(!controller.canAdd && controller.add(times, now: at(9)) == nil)
        #expect(controller.routines.count == Routine.builtIn.count + RoutineController.mostOwn)
    }

    @Test("Renamed, it is the same routine: what was done stays done")
    func rename() throws {
        let desk = Desk()
        let controller = controller(desk)
        let id = try #require(controller.add(times, now: at(8)))
        controller.tick(now: at(9))
        controller.answer(routine: id, slot: "2026-11-20T09:00", done: true, now: at(9, 1))
        controller.rename(id, "Call the optician")
        controller.setSymbol(id, "heart")
        controller.setSymbol(id, "not.a.symbol.of.the.list")
        #expect(controller.routines.last?.id == id && controller.routines.last?.title == "Call the optician")
        #expect(controller.routines.last?.symbol == "heart")
        let again = self.controller(desk, fresh: false, now: at(9, 5))
        #expect(again.days(now: at(9, 5)).first?.slots.map(\.status) == [.done(at: at(9, 1))])
    }

    @Test("Whatever is typed as a name, the banner has one short line and the record stays well formed")
    func typed() throws {
        let desk = Desk()
        let controller = controller(desk)
        let id = try #require(controller.add(times, now: at(8)))
        controller.rename(id, "a,b\n2026-11-20T09:00,done,\r\n" + String(repeating: "é", count: 300))
        controller.tick(now: at(9))
        let title = RoutineBanners.content(for: try #require(desk.banners.first)).title
        #expect(title.count == Routine.nameLimit && !title.contains("\n") && !title.contains("\r"))
        controller.answer(routine: id, slot: "2026-11-20T09:00", done: true, now: at(9, 1))

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)                                    // header, shown, done
        #expect(lines.allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == 5 })
        #expect(lines.dropFirst().allSatisfy { $0.contains(",\(id),") })      // the id, never the name
    }

    @Test("Deleted: its reminders stop and its banner goes; its lines stay in the record")
    func delete() throws {
        let desk = Desk()
        let controller = controller(desk)
        let id = try #require(controller.add(times, now: at(8)))
        controller.tick(now: at(9))
        #expect(desk.banners.count == 1)
        controller.remove(id)
        #expect(!controller.routines.contains { $0.id == id } && desk.settled == [id])
        controller.tick(now: at(9, 11))
        #expect(desk.banners.count == 1 && controller.due(now: at(9, 11)).isEmpty)
        #expect(RoutineStore(file: file).load(since: at(0)).map(\.routine) == [id])
        #expect(!self.controller(desk, fresh: false).routines.contains { $0.id == id })
    }

    @Test("A built-in routine cannot be deleted, renamed or given another kind")
    func builtInStays() {
        let controller = controller(Desk())
        controller.remove(Routine.eyeDrops.id)
        controller.rename(Routine.eyeDrops.id, "Something else")
        controller.setKind(Routine.eyeDrops.id, .atScreen)
        #expect(controller.routines == Routine.builtIn)
    }

    @Test("Settings stored by the two earlier versions load, and a routine can be added to them")
    func storedBefore() throws {
        // The same two texts as in the core's `ScreenCountTests.storedForm`.
        let first = """
            [{"id":"eye-drops","name":"Eye drops","symbol":"drop","isOn":true,"onSince":801000000,\
            "schedule":{"timesOfDay":{"times":[{"hour":8,"minute":0},{"hour":12,"minute":30}]}}}]
            """
        let second = """
            [{"id":"eye-drops","name":"Eye drops","symbol":"drop","isOn":false,\
            "schedule":{"timesOfDay":{"times":[{"hour":8,"minute":0}],"weekdays":[2,3,4,5,6]}}},\
            {"id":"heated-mask","name":"Heated eye mask","symbol":"eye","isOn":true,"onSince":801000000,"sessionMinutes":12,\
            "schedule":{"timesPerWeek":{"count":2,"weekdays":[3,5],"time":{"hour":18,"minute":15}}}}]
            """
        for (text, on) in [(first, "eye-drops"), (second, "heated-mask")] {
            UserDefaults().removePersistentDomain(forName: suite)
            defaults.set(Data(text.utf8), forKey: "routines")
            let controller = controller(Desk(), fresh: false)
            #expect(controller.routines.map(\.id) == Routine.builtIn.map(\.id))
            #expect(controller.routines.filter(\.isOn).map(\.id) == [on])
            let id = try #require(controller.add(water, now: at(9)))
            #expect(self.controller(Desk(), fresh: false).routines.map(\.id) == Routine.builtIn.map(\.id) + [id])
        }
    }

    @Test("Another kind of schedule: what waited no longer waits, and the new one asks from now")
    func kind() throws {
        let desk = Desk()
        let controller = controller(desk)
        let id = try #require(controller.add(times, now: at(8)))
        controller.tick(now: at(9))
        controller.setKind(id, .atScreen, now: at(9, 1))
        #expect(controller.routines.last?.screenMinutes == 60 && desk.settled == [id])
        #expect(controller.due(now: at(9, 2)).isEmpty)
        controller.setScreenMinutes(id, 3)
        #expect(controller.routines.last?.screenMinutes == 15)
        controller.setKind(id, .timesPerWeek, now: at(9, 3))
        #expect(controller.days(now: at(9, 3)).first?.week?.target == 3)
    }

    @Test("A timer given to a routine of times: run to its end, it marks the waiting time done")
    func timer() throws {
        let desk = Desk()
        let controller = controller(desk)
        let id = try #require(controller.add(times, now: at(8)))
        controller.setTimer(id, true)
        #expect(controller.routines.last?.sessionMinutes == 10)
        controller.tick(now: at(9))
        controller.didIt(id, now: at(9, 12))             // what the timer's end calls
        #expect(controller.days(now: at(9, 13)).first?.slots.map(\.status) == [.done(at: at(9, 12))])
        controller.setTimer(id, false)
        #expect(controller.routines.last?.sessionMinutes == nil)
    }

    // MARK: Every N minutes at the screen

    @Test("After its minutes at the screen: one banner, and no repeat ten minutes later")
    func atScreen() throws {
        let desk = Desk()
        let controller = controller(desk)
        let id = try #require(controller.add(water, now: at(9)))
        run(controller, from: at(9), minutes: 59)
        #expect(desk.banners.isEmpty && controller.days(now: at(9, 59)).first?.minutesLeft == 1)
        run(controller, from: at(9, 59), minutes: 1)
        #expect(desk.banners.map(\.routine.id) == [id])
        #expect(desk.banners.first?.slot?.key == "2026-11-20#1" && desk.banners.first?.kept == false)
        run(controller, from: at(10), minutes: 30)
        #expect(desk.banners.count == 1)
        #expect(controller.due(now: at(10, 30)).count == 1)         // still in the panel and the menu bar
    }

    @Test("Nobody there: the count does not move, and nothing is shown to an empty chair")
    func nobodyThere() throws {
        let desk = Desk()
        let controller = controller(desk)
        _ = try #require(controller.add(water, now: at(9)))
        run(controller, from: at(9), minutes: 30)
        desk.present = false
        run(controller, from: at(9, 30), minutes: 90)
        #expect(desk.banners.isEmpty && controller.days(now: at(11)).first?.minutesLeft == 60)
    }

    @Test("Done starts the count again; Later brings it back once after fifteen minutes")
    func doneAndLater() throws {
        let desk = Desk()
        let controller = controller(desk)
        let id = try #require(controller.add(water, now: at(9)))
        run(controller, from: at(9), minutes: 62)
        controller.answer(routine: id, slot: "2026-11-20#1", done: false, now: at(10, 2))
        run(controller, from: at(10, 2), minutes: 14)
        #expect(desk.banners.count == 1)
        run(controller, from: at(10, 16), minutes: 2)
        #expect(desk.banners.count == 2)
        controller.answer(routine: id, slot: "2026-11-20#1", done: true, now: at(10, 20))
        #expect(controller.days(now: at(10, 20)).first?.minutesLeft == 60)
        run(controller, from: at(10, 20), minutes: 59)
        #expect(desk.banners.count == 2)
        run(controller, from: at(11, 19), minutes: 1)
        #expect(desk.banners.last?.slot?.key == "2026-11-20#2")
    }

    // MARK: Gently

    @Test("Two due at the same moment: one banner, the other five minutes later, the time of day first")
    func twoAtOnce() throws {
        let desk = Desk()
        let controller = controller(desk)
        let screen = try #require(controller.add(water, now: at(8)))
        let timed = try #require(controller.add(times, now: at(8)))      // 09:00
        run(controller, from: at(8), minutes: 60)                        // both fall due at 09:00
        #expect(desk.banners.map(\.routine.id) == [timed])
        #expect(controller.due(now: at(9)).count == 2)                   // the panel shows both at once
        run(controller, from: at(9), minutes: 4)
        #expect(desk.banners.count == 1)
        run(controller, from: at(9, 4), minutes: 1)
        #expect(desk.banners.map(\.routine.id) == [timed, screen])
        #expect(desk.banners.last?.kept == true)
    }

    @Test("At most four banners in an hour, over all routines; the fifth comes when the hour has room")
    func hourlyLimit() throws {
        let desk = Desk()
        let controller = controller(desk)
        for minute in [0, 1, 2, 3, 4] {
            let id = try #require(controller.add(times, now: at(8)))
            controller.setTimes(id, [TimeOfDay(hour: 9, minute: minute)])
        }
        run(controller, from: at(9, 4), minutes: 50)
        #expect(desk.banners.count == 4)
        #expect(Set(desk.banners.map(\.routine.id)).count == 4)          // four routines, no repeat squeezed in
        run(controller, from: at(9, 54), minutes: 12)
        #expect(desk.banners.count == 5)
    }

    @Test("Quiet for today: no banner, what waits is still listed; tomorrow it reminds again")
    func quiet() throws {
        let desk = Desk()
        let controller = controller(desk)
        let id = try #require(controller.add(times, now: at(8)))
        controller.setQuiet(true, now: at(8, 30))
        run(controller, from: at(8, 59), minutes: 30)
        #expect(desk.banners.isEmpty && controller.due(now: at(9, 29)).map(\.routine.id) == [id])
        let again = self.controller(desk, fresh: false, now: at(9, 30))
        #expect(again.isQuiet(now: at(9, 30)) && !again.isQuiet(now: at(9, 30, day: 21)))
        again.tick(now: at(9, 0, day: 21))
        #expect(desk.banners.count == 1)

        controller.setQuiet(false, now: at(9, 30))
        controller.tick(now: at(9, 30))
        #expect(desk.banners.count == 2)                                 // undone: the waiting one is shown
    }

    // MARK: The panel

    @Test("Folded, the panel names the soonest thing to come")
    func nextLine() throws {
        let desk = Desk()
        let controller = controller(desk)
        _ = try #require(controller.add(water, now: at(9)))
        let timed = try #require(controller.add(times, now: at(8)))
        controller.setTimes(timed, [TimeOfDay(hour: 11)])
        controller.rename(timed, "Stretch")
        run(controller, from: at(9), minutes: 20)
        let days = controller.days(now: at(9, 20))
        #expect(RoutineFold.next(of: days, now: at(9, 20)) == "Next: Drink water in about 40 min at the screen")
        #expect(RoutineFold.next(of: days.filter { $0.screen == nil }, now: at(9, 20))?.hasPrefix("Next: Stretch at ") == true)
        #expect(RoutineFold.next(of: [], now: at(9, 20)) == nil)
    }
}
