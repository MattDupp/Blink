import Foundation
import Testing
import BlinkCore
@testable import BlinkMonitor

/// The routines as the app runs them: a clock given by hand, somebody there or not, and
/// what the controller asks to be shown. No banner is really shown by these tests.
@MainActor
@Suite("Routines in the app", .serialized)
struct RoutineControllerTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    /// A moment of Friday 20 November 2026, on the wall clock of Paris.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// What a test watches: the reminders asked for, and whether somebody is there.
    @MainActor
    final class Desk {
        var banners: [RoutineBanner] = []
        var settled: [String] = []
        var present = true
    }

    private let id = Routine.eyeDrops.id
    private let suite = "local.blinkmonitor.routine-tests"
    private var file: URL { FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-routine-tests.csv") }

    /// A controller on settings and a record of its own. `fresh` false: as after a relaunch.
    private func controller(_ desk: Desk, fresh: Bool = true, now: Date? = nil) -> RoutineController {
        if fresh {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let controller = RoutineController(defaults: UserDefaults(suiteName: suite)!, store: RoutineStore(file: file),
                                           now: now ?? at(0))
        controller.calendar = calendar
        controller.someoneThere = { desk.present }
        controller.onBanner = { desk.banners.append($0) }
        controller.onSettled = { desk.settled.append($0.id) }
        return controller
    }

    /// Switched on before the day began, with the times 08:00, 13:00 and 17:00.
    private func switchedOn(_ desk: Desk) -> RoutineController {
        let controller = controller(desk)
        controller.setOn(id, true, now: at(0))
        return controller
    }

    private func statuses(_ controller: RoutineController, now: Date) -> [RoutineSlot.Status] {
        controller.days(now: now).first?.slots.map(\.status) ?? []
    }

    // MARK: Off, then on

    @Test("The routine comes switched off, and says nothing")
    func offAtFirst() {
        let desk = Desk()
        let controller = controller(desk)
        #expect(controller.routines.map(\.id) == Routine.builtIn.map(\.id))
        controller.tick(now: at(9))
        #expect(desk.banners.isEmpty && controller.events.isEmpty && controller.days(now: at(9)).isEmpty)
    }

    @Test("Switched on in the afternoon: no reminder for the times already past")
    func switchedOnLate() {
        let desk = Desk()
        let controller = controller(desk)
        controller.setOn(id, true, now: at(13, 10))
        controller.tick(now: at(13, 11))
        #expect(desk.banners.isEmpty)
        controller.tick(now: at(17))
        #expect(desk.banners.map(\.slot?.key) == ["2026-11-20T17:00"])
    }

    // MARK: Reminding

    @Test("A reminder waits for you to be back, then says it was kept")
    func keptUntilBack() {
        let desk = Desk()
        let controller = switchedOn(desk)
        desk.present = false
        controller.tick(now: at(8))
        controller.tick(now: at(8, 20))
        #expect(desk.banners.isEmpty)
        #expect(controller.due(now: at(8, 20)).count == 1)      // the menu bar already shows it

        desk.present = true
        controller.tick(now: at(8, 40))
        #expect(desk.banners.count == 1)
        #expect(desk.banners.first?.kept == true)
        #expect(desk.banners.first?.slot?.key == "2026-11-20T08:00")
    }

    @Test("On time it is not said to be kept; one repeat after ten minutes, then silence")
    func oneRepeat() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.tick(now: at(8).addingTimeInterval(5))
        #expect(desk.banners.count == 1 && desk.banners.first?.kept == false)
        controller.tick(now: at(8, 5))
        #expect(desk.banners.count == 1)
        controller.tick(now: at(8, 11))
        #expect(desk.banners.count == 2)
        for minute in [20, 30, 59] { controller.tick(now: at(9, minute)) }
        #expect(desk.banners.count == 2)
        #expect(statuses(controller, now: at(9, 59)).first == .due)       // still waiting, quietly
    }

    @Test("After a time was slept through, one reminder: the dropped one is written, not shown")
    func sleptThrough() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.tick(now: at(13, 10))
        #expect(desk.banners.map(\.slot?.key) == ["2026-11-20T13:00"])
        #expect(controller.events.filter { $0.action == .missed }.map(\.slot) == ["2026-11-20T08:00"])
        controller.tick(now: at(13, 11))
        #expect(controller.events.filter { $0.action == .missed }.count == 1)
    }

    // MARK: Done and Later

    @Test("Done from the banner: the time is done and its banner taken back")
    func doneFromBanner() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.tick(now: at(8))
        controller.answer(routine: id, slot: "2026-11-20T08:00", done: true, now: at(8, 2))
        #expect(statuses(controller, now: at(8, 3)) == [.done(at: at(8, 2)), .upcoming, .upcoming])
        #expect(desk.settled == [id])
        #expect(controller.due(now: at(8, 3)).isEmpty)
        controller.tick(now: at(8, 30))
        #expect(desk.banners.count == 1)
    }

    @Test("Later puts it off fifteen minutes, then it comes back")
    func laterFromPanel() throws {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.tick(now: at(8))
        let slot = try #require(controller.due(now: at(8, 1)).first?.due)
        controller.later(slot, now: at(8, 1))
        #expect(statuses(controller, now: at(8, 2)).first == .later(until: at(8, 16)))
        #expect(controller.due(now: at(8, 2)).isEmpty)          // no dot in the menu bar meanwhile
        controller.tick(now: at(8, 15))
        #expect(desk.banners.count == 1)
        controller.tick(now: at(8, 16))
        #expect(desk.banners.count == 2)
    }

    @Test("A banner answered after its time was dropped changes nothing")
    func staleAnswer() {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.tick(now: at(8))
        controller.answer(routine: id, slot: "2026-11-20T08:00", done: true, now: at(13, 30))
        #expect(statuses(controller, now: at(13, 30)) == [.missed, .due, .upcoming])
        controller.answer(routine: "unknown", slot: "2026-11-20T13:00", done: true, now: at(13, 30))
        #expect(statuses(controller, now: at(13, 30))[1] == .due)
    }

    @Test("The test reminder is shown and leaves no trace")
    func testReminder() {
        let desk = Desk()
        let controller = controller(desk)
        controller.sendTest(id)
        #expect(desk.banners.count == 1 && desk.banners.first?.slot == nil)
        #expect(controller.events.isEmpty)
    }

    // MARK: Kept between launches

    @Test("After a relaunch: the times, the switch and what was done are still there, and nothing is shown twice")
    func relaunch() {
        let desk = Desk()
        let first = switchedOn(desk)
        first.setTimes(id, [TimeOfDay(hour: 9, minute: 30), TimeOfDay(hour: 8)])
        first.tick(now: at(8))
        #expect(desk.banners.count == 1)

        let second = controller(desk, fresh: false, now: at(8, 1))
        #expect(second.routines.first?.isOn == true)
        #expect(second.routines.first?.times.map(\.text) == ["08:00", "09:30"])
        second.tick(now: at(8, 1))
        #expect(desk.banners.count == 1)        // already shown before the relaunch
        second.done(second.due(now: at(8, 2))[0].due!, now: at(8, 2))

        let third = controller(desk, fresh: false, now: at(8, 3))
        #expect(statuses(third, now: at(8, 3)) == [.done(at: at(8, 2)), .upcoming])
    }

    // MARK: Editing the times

    @Test("Times can be added, changed and removed, but not all of them")
    func editing() {
        let desk = Desk()
        let controller = switchedOn(desk)
        func times() -> [String] { controller.routines[0].times.map(\.text) }

        controller.addTime(id)
        #expect(times() == ["08:00", "13:00", "17:00", "18:00"])
        controller.setTime(id, from: TimeOfDay(hour: 18), to: TimeOfDay(hour: 7, minute: 45))
        #expect(times() == ["07:45", "08:00", "13:00", "17:00"])
        controller.setTime(id, from: TimeOfDay(hour: 13), to: TimeOfDay(hour: 17))       // onto another one
        #expect(times() == ["07:45", "08:00", "17:00"])
        for time in controller.routines[0].times { controller.removeTime(id, time) }
        #expect(times() == ["17:00"])
        controller.setTimes(id, [TimeOfDay(hour: 23)])
        controller.addTime(id)
        #expect(times() == ["00:00", "23:00"])
    }

    @Test("While Settings is open the rows keep their place and a double is kept; closing sorts and merges")
    func editingRows() {
        let desk = Desk()
        let controller = switchedOn(desk)
        func rows() -> [String] { controller.shownTimes(of: controller.routines[0]).map(\.text) }
        func stored() -> [String] { controller.routines[0].times.map(\.text) }
        #expect(rows() == ["08:00", "13:00", "17:00"])

        // Stepping the first time past the second: the row being edited stays first.
        controller.setTime(id, at: 0, to: TimeOfDay(hour: 14))
        #expect(rows() == ["14:00", "13:00", "17:00"])
        #expect(stored() == ["13:00", "14:00", "17:00"])          // the reminders follow at once

        // Onto another time: no row vanishes, and the double is said.
        controller.setTime(id, at: 0, to: TimeOfDay(hour: 13))
        #expect(rows() == ["13:00", "13:00", "17:00"])
        #expect(controller.double(of: 0, in: controller.routines[0]) == 1)
        #expect(controller.double(of: 2, in: controller.routines[0]) == nil)
        #expect(stored() == ["13:00", "17:00"])                   // one reminder at 13:00
        // And off it again: nothing was lost.
        controller.setTime(id, at: 0, to: TimeOfDay(hour: 9))
        #expect(rows() == ["09:00", "13:00", "17:00"] && stored() == ["09:00", "13:00", "17:00"])

        controller.addTimeRow(id)
        controller.setTime(id, at: 3, to: TimeOfDay(hour: 7))
        #expect(rows() == ["09:00", "13:00", "17:00", "07:00"])
        controller.removeTime(id, at: 1)
        #expect(rows() == ["09:00", "17:00", "07:00"])

        // The window closes: sorted, as stored.
        controller.endEditing()
        #expect(rows() == ["07:00", "09:00", "17:00"])
    }

    // MARK: Somebody there

    @Test("With the camera paused, an awake screen counts as somebody there; a sleeping one does not")
    func presence() {
        let model = MonitorModel(preferences: .temporary(), history: HistoryController(store: SampleData.scratchHistory()),
                                 initial: MonitorModel.InitialState())
        #expect(!model.someoneAtScreen())           // camera on, no face yet
        var update = MonitorUpdate()
        update.live.faceFound = true
        model.apply(update)
        #expect(model.someoneAtScreen())

        model.pause(for: .untilResumed)
        #expect(model.someoneAtScreen())            // a pause of the camera does not silence routines
        model.setAsleep(true)
        #expect(!model.someoneAtScreen())
        model.setAsleep(false)
        model.resume()
    }

    // MARK: Days, sound, and the built-in ones

    @Test("A routine at times of day can keep to some days; all seven is every day, and one day always stays")
    func daysOfTheWeek() throws {
        let desk = Desk()
        let controller = switchedOn(desk)
        // (1 = Sunday.) Not at the weekend:
        controller.setDay(id, 1, on: false)
        controller.setDay(id, 7, on: false)
        var routine = try #require(controller.routines.first { $0.id == id })
        #expect(routine.schedule == .timesOfDay(times: Routine.eyeDrops.times, weekdays: [2, 3, 4, 5, 6]))
        #expect(RoutineWords.days([2, 3, 4, 5, 6], calendar: calendar).hasPrefix("on ") && RoutineWords.days(nil) == "every day")
        controller.setDay(id, 1, on: true)
        controller.setDay(id, 7, on: true)
        routine = try #require(controller.routines.first { $0.id == id })
        #expect(routine.schedule == .timesOfDay(times: Routine.eyeDrops.times, weekdays: nil), "all seven days is every day again")
        for weekday in 1...7 { controller.setDay(id, weekday, on: false) }
        routine = try #require(controller.routines.first { $0.id == id })
        if case .timesOfDay(_, let days) = routine.schedule { #expect(days?.count == 1) } else { Issue.record("not at times of day") }
    }

    @Test("A routine is silent until it is given a sound, and routines stored before the switch existed are still read")
    func soundSwitch() throws {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.tick(now: at(8))
        #expect(RoutineBanners.content(for: try #require(desk.banners.first)).sound == nil)
        controller.setSound(id, true)
        let loud = RoutineBanner(routine: try #require(controller.routines.first { $0.id == id }), slot: nil)
        #expect(RoutineBanners.content(for: loud).sound != nil)

        // As stored by an earlier version: no "soundOn", no "hidden".
        let old = #"{"id":"eye-drops","name":"Eye drops","symbol":"drop","isOn":true,"schedule":{"timesOfDay":{"times":[{"hour":8,"minute":0}]}}}"#
        let read = try JSONDecoder().decode(Routine.self, from: Data(old.utf8))
        #expect(!read.playsSound && !read.isHidden && read.isOn)
    }

    @Test("A built-in routine can be taken out of Settings and brought back with its times")
    func hidingBuiltIn() throws {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.setTime(id, from: TimeOfDay(hour: 13), to: TimeOfDay(hour: 14))
        controller.hide(id)
        var routine = try #require(controller.routines.first { $0.id == id })
        #expect(routine.isHidden && !routine.isOn && controller.hiddenBuiltIn.map(\.id) == [id])
        #expect(controller.days(now: at(9)).allSatisfy { $0.routine.id != id }, "nothing of it is asked while it is hidden")
        controller.unhide(id)
        routine = try #require(controller.routines.first { $0.id == id })
        #expect(!routine.isHidden && controller.hiddenBuiltIn.isEmpty && controller.openCard == id)
        #expect(routine.times.contains(TimeOfDay(hour: 14)), "its times were kept")
        // A routine of your own is deleted, not hidden.
        let own = try #require(controller.add(RoutineTemplate.all[0], now: at(9)))
        controller.hide(own)
        #expect(controller.routines.first { $0.id == own }?.isHidden == false && controller.openCard == own)
    }

    @Test("Each routine's line says when it comes")
    func summaries() {
        let fixed = Calendar(identifier: .gregorian)
        #expect(RoutineWords.summary(.eyeDrops, calendar: fixed).hasSuffix(", every day"))
        #expect(RoutineWords.summary(.eyeDrops, calendar: fixed).contains(" and "))
        #expect(RoutineWords.summary(.heatedMask, calendar: fixed).hasPrefix("3 times a week, at "))
        #expect(RoutineWords.summary(.heatedMask, calendar: fixed).hasSuffix("with a timer of 10 minutes"))
        let water = Routine.made(from: RoutineTemplate.all[0], now: at(0))
        #expect(RoutineWords.summary(water) == "Every 60 minutes at the screen")
        // The two routines the app comes with no longer start at the same time.
        if case .timesPerWeek(_, _, let time) = Routine.heatedMask.schedule {
            #expect(!Routine.eyeDrops.times.contains(time))
        }
    }

    // MARK: The words

    @Test("The banner is silent, names the time, and gives no advice")
    func bannerWords() throws {
        let desk = Desk()
        let controller = switchedOn(desk)
        controller.tick(now: at(8))
        let content = RoutineBanners.content(for: try #require(desk.banners.first))
        #expect(content.sound == nil)
        #expect(content.title == "Eye drops")
        #expect(content.body.hasPrefix("Your ") && content.body.hasSuffix(" reminder."))
        #expect(content.userInfo["slot"] as? String == "2026-11-20T08:00")

        let test = RoutineBanners.content(for: RoutineBanner(routine: .eyeDrops, slot: nil))
        for words in [content.body, test.body] {
            for advice in ["should", "must", "need to", "recommend"] { #expect(!words.contains(advice)) }
        }
    }

    @Test("The made-up days of the screenshots are what they are named")
    func sampleDays() {
        let now = at(16, 42)
        func day(_ scene: SampleData.RoutineScene) -> RoutineDay? {
            let model = SampleData.model(now: now, scene: .watching)
            model.routines.calendar = calendar
            SampleData.routines(in: model, now: now, scene: scene, calendar: calendar)
            return model.routines.days(now: now).first
        }
        #expect(day(.kept)?.next?.time == TimeOfDay(hour: 17))
        #expect(day(.kept)?.due == nil)
        #expect(day(.waiting)?.due?.time == TimeOfDay(hour: 16, minute: 30))
        #expect(day(.putOff)?.putOff?.status == .later(until: at(16, 50)))
        #expect(SampleData.model(now: now, scene: .watching).routines.days(now: now).isEmpty)
    }
}
