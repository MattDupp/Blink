import Foundation
import Testing
@testable import BlinkCore

@Suite("History and reminders")
struct HistoryTests {

    /// A round minute of the clock.
    private let ten = Date(timeIntervalSince1970: 1_800_000_000)

    /// 150 s of frames at 30 a second; one blink every 6 s during the first minute only.
    private func twoAndAHalfMinutes() -> (finished: [MinuteRecord], aggregator: MinuteAggregator) {
        var aggregator = MinuteAggregator()
        var finished: [MinuteRecord] = []
        for frame in 0..<(150 * 30) {
            let second = Double(frame) / 30
            let blink = second < 60 && frame % 180 == 90 ? 1 : 0
            if let done = aggregator.add(at: ten.addingTimeInterval(second), observedSeconds: 1.0 / 30, blinks: blink) {
                finished.append(done)
            }
        }
        return (finished, aggregator)
    }

    // MARK: Minutes

    @Test("150 s of frames = two finished minutes and one being filled")
    func minutesOfTheClock() {
        let (finished, aggregator) = twoAndAHalfMinutes()
        #expect(finished.map(\.start) == [ten, ten.addingTimeInterval(60)])
        #expect(aggregator.current?.start == ten.addingTimeInterval(120))
    }

    @Test("A minute holds its watched time and its blinks")
    func minuteContents() throws {
        let finished = twoAndAHalfMinutes().finished
        try #require(finished.count == 2)
        #expect(abs(finished[0].observedSeconds - 60) < 0.01)
        #expect(finished[0].blinks == 10 && finished[1].blinks == 0)
    }

    @Test("A minute watched for under 20 s has no rate")
    func rateNeedsEvidence() {
        #expect(MinuteRecord(start: ten, observedSeconds: 12, blinks: 3).ratePerMinute == nil)
        #expect(MinuteRecord(start: ten, observedSeconds: 30, blinks: 5).ratePerMinute == 10)
    }

    @Test("Minutes written to disk read back the same")
    func storeRoundTrip() throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(file: folder.appendingPathComponent("history.csv"))
        let finished = twoAndAHalfMinutes().finished
        for minute in finished { #expect(store.append(minute)) }

        let reloaded = store.load(since: ten)
        try #require(reloaded.count == 2)
        #expect(reloaded[0].start == ten && reloaded[0].blinks == 10)
        #expect(abs(reloaded[0].observedSeconds - 60) < 0.06)      // one decimal is kept
        #expect(store.load(since: ten.addingTimeInterval(60)).count == 1)
    }

    @Test("A history file with a damaged line keeps its good lines")
    func damagedLine() throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.csv")
        try "start,observed_seconds,blinks\n2027-01-15T08:00:00Z,58.0,9\nnot a line\n2027-01-15T08:01:00Z,60.0,12\n"
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(HistoryStore(file: file).load(since: .distantPast).map(\.blinks) == [9, 12])
    }

    @Test("A day: watched time, blinks, average, share of low minutes")
    func daySummary() throws {
        let summary = DaySummary(records: twoAndAHalfMinutes().finished, threshold: 10)
        #expect(abs(summary.observedSeconds - 120) < 0.01)
        #expect(summary.blinks == 10)
        #expect(abs(try #require(summary.ratePerMinute) - 5) < 0.01)
        #expect(summary.ratedMinutes == 2 && summary.lowMinutes == 1)
        #expect(summary.lowShare == 0.5)
    }

    @Test("The records of a day are those between its two midnights, whatever the time zone")
    func recordsOfADay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let midnight = calendar.startOfDay(for: ten)
        let records = [-1, 0, 1, 1439, 1440].map {
            MinuteRecord(start: midnight.addingTimeInterval(Double($0) * 60), observedSeconds: 60, blinks: $0 + 2)
        }
        #expect(records.on(ten, calendar: calendar).map(\.blinks) == [2, 3, 1441])
        #expect(records.on(midnight.addingTimeInterval(-3600), calendar: calendar).map(\.blinks) == [1])
        #expect([MinuteRecord]().on(ten, calendar: calendar).isEmpty)

        // The same answer as asking the calendar record by record, which is what it replaces.
        let asked = records.filter { calendar.isDate($0.start, inSameDayAs: ten) }
        #expect(records.on(ten, calendar: calendar) == asked)
    }

    // MARK: The last hour, as the panel draws it

    @Test("A minute recorded AFTER the chart was first drawn appears when it is drawn again")
    func lastHourFollowsTheClock() {
        // The panel once kept the moment it was created: every later minute was "in the
        // future" for it and was never drawn.
        let launch = ten.addingTimeInterval(30)
        let before = [minute(-2, watched: 60, blinks: 12), minute(-1, watched: 60, blinks: 9)]
        let atLaunch = LastHour(minutes: before, current: nil, now: launch)
        #expect(atLaunch.rate(minutesAgo: 1) == 9 && atLaunch.rate(minutesAgo: 2) == 12)
        // The chart in words, for VoiceOver.
        #expect(atLaunch.summary(limit: 10) == "Lowest 9, highest 12. 1 of 2 minutes under the limit of 10")
        #expect(LastHour(minutes: [], current: nil, now: launch).summary(limit: 10) == "Nothing counted in the last hour")

        let later = before + [minute(0, watched: 60, blinks: 14), minute(1, watched: 60, blinks: 15)]
        let twoMinutesOn = LastHour(minutes: later, current: minute(2, watched: 30, blinks: 8), now: launch.addingTimeInterval(120))
        #expect(twoMinutesOn.rate(minutesAgo: 1) == 15 && twoMinutesOn.rate(minutesAgo: 2) == 14)
        #expect(twoMinutesOn.rate(minutesAgo: 0) == 16)                   // the minute in progress
        #expect(twoMinutesOn.rate(minutesAgo: 4) == 12)
        #expect(twoMinutesOn.start(minutesAgo: 2) == ten)
    }

    @Test("The chart holds sixty minutes, says when it is empty, and knows which bar is under the pointer")
    func lastHourEdges() {
        let old = [minute(-75, watched: 60, blinks: 10), minute(-59, watched: 60, blinks: 11)]
        let hour = LastHour(minutes: old, current: nil, now: ten)
        #expect(hour.rate(minutesAgo: 59) == 11 && hour.rates.compactMap { $0 }.count == 1)
        #expect(hour.rate(minutesAgo: 75) == nil && hour.rate(minutesAgo: -1) == nil)
        #expect(LastHour(minutes: [], current: nil, now: ten).isEmpty)
        #expect(LastHour(minutes: [minute(-1, watched: 10, blinks: 2)], current: nil, now: ten).isEmpty)   // too short to have a rate

        #expect(LastHour.minutesAgo(atX: 0, width: 300) == 59)            // the left edge is the oldest
        #expect(LastHour.minutesAgo(atX: 299, width: 300) == 0)
        #expect(LastHour.minutesAgo(atX: 152, width: 300) == 29)
        #expect(LastHour.minutesAgo(atX: -5, width: 300) == 59 && LastHour.minutesAgo(atX: 400, width: 300) == 0)
        #expect(LastHour.minutesAgo(atX: 10, width: 0) == 0)
    }

    // MARK: Reminders

    private func minute(_ index: Int, watched: Double, blinks: Int) -> MinuteRecord {
        MinuteRecord(start: ten.addingTimeInterval(Double(index) * 60), observedSeconds: watched, blinks: blinks)
    }
    private var afterThree: Date { ten.addingTimeInterval(180) }
    private var quiet: [MinuteRecord] {
        [minute(0, watched: 60, blinks: 4), minute(1, watched: 60, blinks: 5), minute(2, watched: 60, blinks: 3)]
    }

    @Test("12 blinks in 3 minutes watched = 4 a minute")
    func recentRate() throws {
        let rate = try #require(ReminderPolicy().recentRate(records: quiet, now: afterThree))
        #expect(abs(rate - 4) < 0.01)
    }

    @Test("Too little watched (you were away): no rate, no reminder")
    func awayGivesNoReminder() {
        var policy = ReminderPolicy()
        #expect(policy.recentRate(records: [minute(2, watched: 40, blinks: 0)], now: afterThree) == nil)
        let due = policy.reminderDue(rate: nil, threshold: 10, now: afterThree)
        #expect(!due)
    }

    @Test("Minutes older than the last three are not counted")
    func oldMinutesIgnored() {
        let old = [minute(-9, watched: 60, blinks: 0), minute(-8, watched: 60, blinks: 0)]
        #expect(ReminderPolicy().recentRate(records: old, now: afterThree) == nil)
    }

    @Test("A rate over the threshold never reminds")
    func healthyRate() {
        var policy = ReminderPolicy()
        let due = policy.reminderDue(rate: 14, threshold: 10, now: afterThree)
        #expect(!due)
    }

    @Test("A low rate reminds once, then waits five minutes")
    func cooldown() {
        var policy = ReminderPolicy()
        let first = policy.reminderDue(rate: 4, threshold: 10, now: afterThree)
        let fourMinutesLater = policy.reminderDue(rate: 4, threshold: 10, now: afterThree.addingTimeInterval(240))
        let fiveMinutesLater = policy.reminderDue(rate: 4, threshold: 10, now: afterThree.addingTimeInterval(301))
        #expect(first)
        #expect(!fourMinutesLater)
        #expect(fiveMinutesLater)
    }

    @Test("Unanswered, the reminder backs off: 5, 15, 30, then 60 minutes, and only the first two make a sound")
    func backOff() {
        var policy = ReminderPolicy()
        // A whole afternoon under the limit, asked once a minute as the app does.
        var shown: [(minute: Int, sound: Bool)] = []
        for minute in 0...200 {
            if let due = policy.reminder(rate: 6, threshold: 10, now: afterThree.addingTimeInterval(Double(minute) * 60)) {
                shown.append((minute, due.sound))
            }
        }
        #expect(shown.map(\.minute) == [0, 5, 20, 50, 110, 170])
        #expect(shown.map(\.sound) == [true, true, false, false, false, false])
    }

    @Test("Above the limit for three minutes, the low stretch is over: the next one starts at five minutes, with its sound")
    func backOffStartsOver() {
        var policy = ReminderPolicy()
        func ask(_ minute: Int, rate: Double?) -> ReminderPolicy.Due? {
            policy.reminder(rate: rate, threshold: 10, now: afterThree.addingTimeInterval(Double(minute) * 60))
        }
        #expect(ask(0, rate: 6)?.sound == true)
        #expect(ask(5, rate: 6)?.sound == true)
        #expect(ask(20, rate: 6)?.sound == false)
        // Two minutes above is a pause, not a recovery: the long wait still holds.
        #expect(ask(21, rate: 12) == nil && ask(22, rate: 12) == nil)
        #expect(ask(23, rate: 6) == nil)
        #expect(policy.unanswered == 3)
        // Three minutes above: over. Away from the screen in between changes nothing.
        #expect(ask(30, rate: 12) == nil && ask(31, rate: nil) == nil && ask(33, rate: 12) == nil)
        #expect(policy.unanswered == 0)
        // Low again, an hour after the last reminder: a first reminder, then five minutes.
        #expect(ask(80, rate: 6)?.sound == true)
        #expect(ask(84, rate: 6) == nil)
        #expect(ask(85, rate: 6)?.sound == true)
    }

    @Test("A blink break that was done answers the reminder: nothing for 20 minutes, then it starts over")
    func quietAfterBlinkBreak() {
        var policy = ReminderPolicy()
        func ask(_ minute: Int) -> ReminderPolicy.Due? {
            policy.reminder(rate: 6, threshold: 10, now: afterThree.addingTimeInterval(Double(minute) * 60))
        }
        #expect(ask(0) != nil)
        policy.blinkBreakDone(at: afterThree.addingTimeInterval(60))
        #expect(ask(5) == nil && ask(10) == nil && ask(20) == nil)
        #expect(ask(21)?.sound == true)
        #expect(ask(25) == nil)
        #expect(ask(26)?.sound == true)
    }

    @Test("A reminder that may not show yet waits, and its wait does not start")
    func heldByTheGate() {
        var policy = ReminderPolicy()
        func ask(_ minute: Int, allowed: Bool) -> ReminderPolicy.Due? {
            policy.reminder(rate: 6, threshold: 10, now: afterThree.addingTimeInterval(Double(minute) * 60), allowed: allowed)
        }
        #expect(ask(0, allowed: false) == nil && ask(1, allowed: false) == nil)
        #expect(policy.unanswered == 0 && policy.lastReminder == nil)
        #expect(ask(2, allowed: true)?.sound == true)
        #expect(ask(6, allowed: true) == nil)
        #expect(ask(7, allowed: true) != nil)
    }

    @Test("Export copies the files that exist under names of their own, and replaces an earlier export")
    func export() throws {
        let home = Fixture.temporaryFolder(), chosen = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: chosen) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let history = home.appendingPathComponent("history.csv"), log = home.appendingPathComponent("routines.csv")
        try "minute,blinks\n".write(to: history, atomically: true, encoding: .utf8)
        let breaks = home.appendingPathComponent("breaks.csv")
        let notes = home.appendingPathComponent("eye-notes.csv")
        let items = DataExport.items(history: history, routineLog: log, breakLog: breaks, eyeNotes: notes)

        // No routine was ever shown: its log does not exist, and that is not an error.
        var copies = try DataExport.copy(items, to: chosen)
        #expect(copies.map(\.lastPathComponent) == ["Blink Monitor history.csv"])

        try "minute,blinks\n1,12\n".write(to: history, atomically: true, encoding: .utf8)
        try "at,routine\n".write(to: log, atomically: true, encoding: .utf8)
        copies = try DataExport.copy(items, to: chosen)
        #expect(copies.map(\.lastPathComponent) == ["Blink Monitor history.csv", "Blink Monitor routine log.csv"])
        try "at,what,note\n".write(to: breaks, atomically: true, encoding: .utf8)
        #expect(try DataExport.copy(items, to: chosen).map(\.lastPathComponent).last == "Blink Monitor break log.csv")
        try "day,at,feeling\n".write(to: notes, atomically: true, encoding: .utf8)
        #expect(try DataExport.copy(items, to: chosen).map(\.lastPathComponent).last == "Blink Monitor eye notes.csv")
        #expect(try String(contentsOf: copies[0], encoding: .utf8).hasSuffix("1,12\n"), "the earlier export was replaced")
        // The app's own files are where they were.
        #expect(FileManager.default.fileExists(atPath: history.path) && FileManager.default.fileExists(atPath: log.path))
        // A folder that cannot be written to is an error, said to the user.
        #expect(throws: (any Error).self) { try DataExport.copy(items, to: chosen.appendingPathComponent("missing")) }
    }

    @Test("While snoozed there is no reminder; afterwards they come back")
    func snooze() {
        var policy = ReminderPolicy()
        policy.snooze(until: afterThree.addingTimeInterval(1800))
        #expect(policy.isSnoozed(at: afterThree.addingTimeInterval(600)))
        let duringSnooze = policy.reminderDue(rate: 4, threshold: 10, now: afterThree.addingTimeInterval(600))
        let afterSnooze = policy.reminderDue(rate: 4, threshold: 10, now: afterThree.addingTimeInterval(1801))
        #expect(!duringSnooze)
        #expect(afterSnooze)

        policy.snooze(until: nil)
        #expect(!policy.isSnoozed(at: afterThree))
    }
}
