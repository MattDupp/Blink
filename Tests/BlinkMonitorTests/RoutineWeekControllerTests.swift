import Foundation
import Testing
import BlinkCore
@testable import BlinkMonitor

/// A routine counted by the week, and its timer, as the app runs them: a clock given by
/// hand, and what the controller asks for. No banner is shown, no sound is played, and
/// no camera is paused by these tests: each of those is a closure the test replaces.
///
/// The week: Monday 16 to Sunday 22 November 2026. Monday, Wednesday, Friday at 17:00.
@MainActor
@Suite("Routines counted by the week, in the app", .serialized)
struct RoutineWeekControllerTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// What a test watches.
    @MainActor
    final class Desk {
        var banners: [RoutineBanner] = []
        var settled: [String] = []
        var present = true
        /// The camera, as the timer sees it.
        var cameraPausedByUser = false
        var pausedUntil: [Date] = []
        var resumed = 0
        var chimes = 0
        var opened = 0
        var closed = 0
    }

    private let id = Routine.heatedMask.id
    private let suite = "local.blinkmonitor.routine-week-tests"
    private var file: URL { FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-routine-week-tests.csv") }

    /// `fresh` false: as after a relaunch, on the same settings and the same record.
    private func controller(_ desk: Desk, fresh: Bool = true, now: Date? = nil) -> RoutineController {
        if fresh {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let controller = RoutineController(defaults: UserDefaults(suiteName: suite)!, store: RoutineStore(file: file),
                                           now: now ?? at(day: 16, 0))
        controller.calendar = calendar
        controller.turns = .always
        // These timelines were written for a mask at 17:00, which is where it started
        // before it moved an hour after the eye drops. (Not after a relaunch: a stored
        // time is the user's, and is read back as it was.)
        if fresh { controller.setWeekTime(id, TimeOfDay(hour: 17)) }
        // As `connect(to:)` wires it: under a timer, nobody is looking.
        controller.someoneThere = { [weak controller] in desk.present && controller?.session.session == nil }
        controller.onBanner = { desk.banners.append($0) }
        controller.onSettled = { desk.settled.append($0.id) }
        controller.session.pauseCamera = { end in
            guard !desk.cameraPausedByUser else { return false }
            desk.pausedUntil.append(end)
            return true
        }
        controller.session.resumeCamera = { _ in desk.resumed += 1 }
        controller.session.chime = { desk.chimes += 1 }
        controller.session.onOpen = { desk.opened += 1 }
        controller.session.onClose = { desk.closed += 1 }
        return controller
    }

    /// Switched on two weeks before: an ordinary week.
    private func switchedOn(_ desk: Desk) -> RoutineController {
        let controller = controller(desk)
        controller.setOn(id, true, now: at(day: 2, 9))
        return controller
    }

    private func week(_ controller: RoutineController, now: Date) -> RoutineWeek? {
        controller.days(now: now).first { $0.routine.id == id }?.week
    }

    // MARK: Reminding through the week

    @Test("It comes switched off; switched on, it reminds on its day and says where the week stands")
    func remindsOnItsDay() {
        let desk = Desk()
        let controller = controller(desk)
        controller.tick(now: at(day: 16, 18))
        #expect(desk.banners.isEmpty && controller.days(now: at(day: 16, 18)).isEmpty)

        controller.setOn(id, true, now: at(day: 2, 9))
        controller.tick(now: at(day: 16, 16, 59))
        #expect(desk.banners.isEmpty)
        #expect(week(controller, now: at(day: 16, 16, 59))?.done == 0)     // the week shows before anything is due
        controller.tick(now: at(day: 16, 17))
        #expect(desk.banners.map(\.slot?.key) == ["2026-11-16"])
        #expect(desk.banners.first?.week?.target == 3)
        #expect(controller.due(now: at(day: 16, 17)).count == 1)           // the menu-bar dot
    }

    @Test("I did it, at any time: it counts, on a day that did not ask and before the time")
    func didItAtAnyTime() {
        let desk = Desk()
        let controller = switchedOn(desk)
        // Monday morning, hours before the reminder.
        controller.didIt(id, now: at(day: 16, 9))
        #expect(week(controller, now: at(day: 16, 9))?.done == 1)
        controller.tick(now: at(day: 16, 17))
        #expect(desk.banners.isEmpty)                                       // nothing left to ask today
        // Tuesday, a day that does not ask.
        controller.didIt(id, now: at(day: 17, 21))
        #expect(week(controller, now: at(day: 17, 21))?.done == 2)
        #expect(controller.events.filter { $0.action == .done }.map(\.slot) == ["2026-11-16", "2026-11-17"])
        // Wednesday asks for the third; done; Friday is silent.
        controller.tick(now: at(day: 18, 17))
        #expect(desk.banners.map(\.slot?.key) == ["2026-11-18"])
        controller.answer(routine: id, slot: "2026-11-18", done: true, now: at(day: 18, 17, 5))
        #expect(week(controller, now: at(day: 18, 18))?.isReached == true)
        controller.tick(now: at(day: 20, 17))
        controller.tick(now: at(day: 21, 17))
        #expect(desk.banners.count == 1)
    }

    @Test("A missed day is asked again the next day, and the miss is written")
    func missedDay() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.didIt(id, now: at(day: 16, 18))
        controller.tick(now: at(day: 18, 17))                               // Wednesday: shown, not done
        controller.tick(now: at(day: 19, 9))
        #expect(controller.events.filter { $0.action == .missed }.map(\.slot) == ["2026-11-18"])
        controller.tick(now: at(day: 19, 17))                               // Thursday asks instead
        #expect(desk.banners.map(\.slot?.key) == ["2026-11-18", "2026-11-19"])
    }

    @Test("Undo takes back a done pressed by mistake, and only today's")
    func undo() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.didIt(id, now: at(day: 16, 18))
        controller.undo(id, now: at(day: 17, 9))                            // Tuesday: nothing of today to take back
        #expect(week(controller, now: at(day: 17, 9))?.done == 1)
        controller.didIt(id, now: at(day: 17, 10))
        controller.undo(id, now: at(day: 17, 10, 1))
        #expect(week(controller, now: at(day: 17, 11))?.done == 1)
        #expect(controller.events.last?.action == .undone)
    }

    @Test("After a relaunch on Friday, Monday's is still counted: the record is read for the whole week")
    func relaunch() {
        let desk = Desk()
        var controller = switchedOn(desk)
        controller.didIt(id, now: at(day: 16, 18))
        controller = self.controller(desk, fresh: false, now: at(day: 20, 9))
        #expect(week(controller, now: at(day: 20, 9))?.done == 1)
        // And a tick on Sunday does not forget Monday either.
        controller.tick(now: at(day: 22, 23))
        #expect(week(controller, now: at(day: 22, 23))?.done == 1)
    }

    // MARK: The timer

    @Test("The timer pauses the camera for its length, and its end marks the routine done")
    func timerToItsEnd() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.tick(now: at(day: 16, 17))
        controller.startSession(id, now: at(day: 16, 17, 2))
        #expect(controller.session.session?.end == at(day: 16, 17, 12))
        #expect(desk.pausedUntil == [at(day: 16, 17, 12)])
        #expect(desk.opened == 1 && desk.settled == [id])                   // window shown, banner taken back
        #expect(controller.events.last?.action == .started)

        controller.tick(now: at(day: 16, 17, 11))
        #expect(controller.session.session != nil && week(controller, now: at(day: 16, 17, 11))?.done == 0)

        controller.session.check(now: at(day: 16, 17, 12))
        #expect(controller.session.session == nil && controller.session.finished != nil)
        #expect(desk.chimes == 1 && desk.resumed == 1)
        let done = controller.events.last { $0.action == .done }
        #expect(done?.at == at(day: 16, 17, 12) && done?.slot == "2026-11-16")
        #expect(week(controller, now: at(day: 16, 17, 13))?.done == 1)
        #expect(controller.due(now: at(day: 16, 17, 13)).isEmpty)

        controller.session.check(now: at(day: 16, 17, 13))                  // looked at again: nothing twice
        #expect(desk.chimes == 1 && week(controller, now: at(day: 16, 17, 13))?.done == 1)
    }

    @Test("Stopped before its end: nothing is marked, and the camera comes back")
    func timerStopped() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.startSession(id, now: at(day: 16, 17))
        controller.session.stop()
        #expect(controller.session.session == nil && controller.session.finished == nil)
        #expect(desk.resumed == 1 && desk.chimes == 0 && desk.closed == 1)
        #expect(week(controller, now: at(day: 16, 17, 30))?.done == 0)
        controller.session.check(now: at(day: 16, 18))
        #expect(week(controller, now: at(day: 16, 18))?.done == 0)
    }

    @Test("A second timer cannot be started over the first, and a routine without one has none")
    func oneTimer() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.startSession(id, now: at(day: 16, 17))
        controller.startSession(id, now: at(day: 16, 17, 5))
        #expect(controller.session.session?.start == at(day: 16, 17))
        #expect(desk.pausedUntil.count == 1)
        controller.session.stop()
        controller.startSession(Routine.eyeDrops.id, now: at(day: 16, 17, 6))
        #expect(controller.session.session == nil)
    }

    @Test("The Mac slept past the end: marked done at the end, without a sound")
    func timerSleptThrough() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.startSession(id, now: at(day: 16, 17))
        controller.tick(now: at(day: 16, 19))                               // the 20-second look finds it over
        #expect(controller.session.session == nil && controller.session.finished == nil)
        #expect(desk.chimes == 0 && desk.closed == 1)
        #expect(controller.events.last { $0.action == .done }?.at == at(day: 16, 17, 10))
    }

    @Test("A pause the user chose is left alone, before and after the timer")
    func usersOwnPause() {
        let desk = Desk()
        desk.cameraPausedByUser = true
        let controller = switchedOn(desk)
        controller.startSession(id, now: at(day: 16, 17))
        controller.session.check(now: at(day: 16, 17, 10))
        #expect(desk.pausedUntil.isEmpty && desk.resumed == 0)
        #expect(week(controller, now: at(day: 16, 17, 11))?.done == 1)
    }

    @Test("Under the timer the other reminders are kept, and come when it is over")
    func othersWait() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.setTimes(Routine.eyeDrops.id, [TimeOfDay(hour: 17, minute: 5)])
        controller.setOn(Routine.eyeDrops.id, true, now: at(day: 2, 9))
        controller.startSession(id, now: at(day: 16, 16, 58))
        controller.tick(now: at(day: 16, 17, 6))
        #expect(desk.banners.isEmpty)
        controller.tick(now: at(day: 16, 17, 9))                            // the timer ends at 17:08
        #expect(desk.banners.map(\.routine.id) == [Routine.eyeDrops.id])
        #expect(desk.banners.first?.kept == true)
    }

    @Test("Switching the routine off stops its timer")
    func switchedOffUnderTimer() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.startSession(id, now: at(day: 16, 17))
        controller.setOn(id, false)
        #expect(controller.session.session == nil && desk.resumed == 1)
    }

    // MARK: Settings and banner

    @Test("The count, the days and the timer's length are kept within sense, and stored")
    func settings() {
        let desk = Desk()
        var controller = controller(desk)
        controller.setWeekCount(id, 0)
        controller.setWeekTime(id, TimeOfDay(hour: 20, minute: 30))
        controller.setSessionMinutes(id, 500)
        for day in [2, 4, 6] { controller.setWeekday(id, day, preferred: false) }   // the last one stays
        controller.setWeekday(id, 1, preferred: true)
        controller = self.controller(desk, fresh: false)
        let routine = controller.routines.first { $0.id == id }
        #expect(routine?.schedule == .timesPerWeek(count: 1, weekdays: [1, 6], time: TimeOfDay(hour: 20, minute: 30)))
        #expect(routine?.sessionMinutes == 60)
        // A routine without a timer does not gain one, and the eye drops keep their times.
        controller.setSessionMinutes(Routine.eyeDrops.id, 5)
        controller.setWeekCount(Routine.eyeDrops.id, 5)
        #expect(controller.routines.first { $0.id == Routine.eyeDrops.id } == Routine.eyeDrops)
    }

    @Test("The banner of a routine with a timer offers to start it, and says where the week stands")
    func banner() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.didIt(id, now: at(day: 16, 12))
        controller.tick(now: at(day: 18, 17))
        let content = RoutineBanners.content(for: desk.banners[0])
        #expect(content.categoryIdentifier == "routine-timed")
        #expect(content.title == "Heated eye mask")
        #expect(content.body.hasSuffix("1 of 3 done this week."))
        #expect(content.sound == nil)
        let drops = RoutineBanners.content(for: RoutineBanner(routine: .eyeDrops, slot: nil))
        #expect(drops.categoryIdentifier == "routine")
    }
}
