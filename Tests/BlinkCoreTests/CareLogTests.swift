import Foundation
import Testing
@testable import BlinkCore

/// The break log, what a week kept, and the one comparison, on days written by hand.
@Suite("What was kept")
struct CareLogTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        return calendar
    }

    /// November 2026, at an hour of the day.
    private func at(_ day: Int, _ hour: Double = 10) -> Date {
        (calendar.date(from: DateComponents(year: 2026, month: 11, day: day)) ?? Date()).addingTimeInterval(hour * 3600)
    }

    /// Two hours at the screen on a day, at a rate.
    private func day(_ day: Int, rate: Int) -> [MinuteRecord] {
        (0..<120).map { MinuteRecord(start: at(day, 9).addingTimeInterval(Double($0) * 60), observedSeconds: 60, blinks: rate) }
    }

    private func breaks(_ day: Int, _ count: Int) -> [CareEvent] {
        (0..<count).map { CareEvent(at: at(day, 9.5).addingTimeInterval(Double($0) * 1200), kind: .lookAway) }
    }

    @Test("The log is a file of its own: written, read back, erased, and gone with Delete Everything")
    func store() throws {
        let base = Fixture.temporaryFolder()
        let folder = base.appendingPathComponent("BlinkMonitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = CareStore(file: folder.appendingPathComponent("breaks.csv"))
        #expect(store.load(since: .distantPast).isEmpty, "no file yet is not an error")
        let events = [CareEvent(at: at(20, 10), kind: .lookAway), CareEvent(at: at(20, 11), kind: .longBreak, sameAbsence: true),
                      CareEvent(at: at(20, 12), kind: .skipped), CareEvent(at: at(20, 14), kind: .blinkReminder),
                      CareEvent(at: at(20, 14.1), kind: .blinkBreak), CareEvent(at: at(20, 15), kind: .cutShort)]
        for event in events { #expect(store.append(event)) }
        #expect(store.load(since: .distantPast) == events)
        #expect(store.load(since: at(20, 13)).count == 3)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(text.hasPrefix("at,what,note\n") && text.contains(",long-break,same-absence\n"))
        // A line nobody can read is skipped, not fatal.
        try (text + "nonsense\n2026-11-20T16:00:00Z,unknown-kind,\n").write(to: store.file, atomically: true, encoding: .utf8)
        #expect(store.load(since: .distantPast) == events)

        #expect(store.erase() && store.load(since: .distantPast).isEmpty && store.erase())
        // "Delete Everything and Quit" removes the app's folder, and this file with it.
        store.append(events[0])
        let domain = "local.blinkmonitor.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        try Uninstall.deleteEverything(folder: folder, defaults: defaults, domain: domain)
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
    }

    @Test("The end of a look-away break is written as what happened")
    func outcomes() {
        let now = at(20)
        #expect(CareEvent(BreakOutcome(kind: .short, ending: .away), at: now).kind == .lookAway)
        #expect(CareEvent(BreakOutcome(kind: .short, ending: .onTrust), at: now).kind == .lookAway)
        #expect(CareEvent(BreakOutcome(kind: .long, ending: .away, sameAbsence: true), at: now) == CareEvent(at: now, kind: .longBreak, sameAbsence: true))
        #expect(CareEvent(BreakOutcome(kind: .short, ending: .skipped), at: now).kind == .skipped)
        #expect(CareEvent(BreakOutcome(kind: .long, ending: .cutShort), at: now).kind == .cutShort)
    }

    @Test("A week's count: a break that grew long is one break, a mark taken back is not counted, other weeks are not in it")
    func kept() {
        let week = HistoryWeeks.week(0, now: at(20, 16), calendar: calendar)       // 14 to 20 November
        let care = [CareEvent(at: at(16), kind: .lookAway), CareEvent(at: at(16, 10.1), kind: .longBreak, sameAbsence: true),
                    CareEvent(at: at(17), kind: .longBreak), CareEvent(at: at(17, 11), kind: .skipped),
                    CareEvent(at: at(18), kind: .cutShort), CareEvent(at: at(18, 14), kind: .blinkReminder),
                    CareEvent(at: at(18, 14.1), kind: .blinkBreak), CareEvent(at: at(19, 14), kind: .blinkReminder),
                    CareEvent(at: at(10), kind: .lookAway)]                        // the week before
        let routines = [RoutineEvent(at: at(16, 8), routine: "eye-drops", slot: "a", action: .done),
                        RoutineEvent(at: at(16, 13), routine: "eye-drops", slot: "b", action: .done),
                        RoutineEvent(at: at(16, 13.1), routine: "eye-drops", slot: "b", action: .undone),
                        RoutineEvent(at: at(16, 17), routine: "eye-drops", slot: "c", action: .shown),
                        RoutineEvent(at: at(12, 8), routine: "eye-drops", slot: "d", action: .done)]
        let kept = Kept(week: week, care: care, routines: routines)
        #expect(kept.breaksTaken == 2 && kept.longBreaks == 2 && kept.breaksNotTaken == 2)
        #expect(kept.blinkBreaks == 1 && kept.blinkReminders == 2 && kept.routinesDone == 1)
        #expect(Kept(week: HistoryWeeks.week(2, now: at(20, 16), calendar: calendar), care: care, routines: routines).isEmpty)
    }

    @Test("The comparison is stated only with five days on each side, and never counts today or the days before the log")
    func finding() {
        let now = at(20, 16)
        // Ten days, 6 to 15 November: five with 8 breaks at 14 a minute, five with 2 at 11.
        var records: [MinuteRecord] = [], care: [CareEvent] = []
        for (index, day) in (6...15).enumerated() {
            let many = index % 2 == 0
            records += self.day(day, rate: many ? 14 : 11)
            care += breaks(day, many ? 8 : 2)
        }
        let finding = KeptFinding.find(records: records, care: care, now: now, calendar: calendar)
        #expect(finding == KeptFinding(breaks: 8, daysWith: 5, rateWith: 14, daysWithout: 5, rateWithout: 11))

        // Nine days: one side has four. Nothing is said.
        let nine = records.filter { $0.start >= at(7, 0) }
        #expect(KeptFinding.find(records: nine, care: care, now: now, calendar: calendar) == nil)
        // Every day alike: there are no two groups.
        let alike = (6...15).flatMap { breaks($0, 5) }
        #expect(KeptFinding.find(records: records, care: alike, now: now, calendar: calendar) == nil)
        // No log at all: nothing was written down, so nothing is compared.
        #expect(KeptFinding.find(records: records, care: [], now: now, calendar: calendar) == nil)

        // Days before the first line of the log are not "days without breaks": a log
        // that starts on the 11th leaves five days, too few.
        let late = care.filter { $0.at >= at(11, 0) }
        #expect(KeptFinding.find(records: records, care: late, now: now, calendar: calendar) == nil)
        // Today is not over: a low morning must not join the count.
        let withToday = records + day(20, rate: 2)
        #expect(KeptFinding.find(records: withToday, care: care + breaks(20, 9), now: now, calendar: calendar) == finding)
        // A day with less than an hour at the screen does not count on either side.
        let short = (0..<30).map { MinuteRecord(start: at(16, 9).addingTimeInterval(Double($0) * 60), observedSeconds: 60, blinks: 30) }
        #expect(KeptFinding.find(records: records + short, care: care + breaks(16, 9), now: now, calendar: calendar) == finding)
    }
}
