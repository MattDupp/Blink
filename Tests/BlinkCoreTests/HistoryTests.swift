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
