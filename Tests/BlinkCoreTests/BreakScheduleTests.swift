import Foundation
import Testing
@testable import BlinkCore

/// The look-away breaks, on timelines written by hand: one observation a second, as the
/// app gives them, with stretches where nothing is observed at all.
@Suite("Look-away breaks")
struct BreakScheduleTests {

    /// A day at the screen, told second by second.
    private struct Timeline {
        var schedule: BreakSchedule
        var time: Double
        /// Every event, with the second it happened at (counted from the start).
        var log: [(at: Double, event: BreakSchedule.Event)] = []
        private let origin: Double

        init(_ plan: BreakPlan, startingAt origin: Double = 0) {
            schedule = BreakSchedule(plan: plan)
            self.origin = origin
            time = origin
            note(schedule.observe(time: time, faceFound: true))
        }

        private mutating func note(_ events: [BreakSchedule.Event]) {
            log += events.map { (time - origin, $0) }
        }

        /// Someone at the screen (or not) for this many seconds, seen once a second.
        mutating func watch(_ seconds: Int, face: Bool = true, quiet: Bool = false, hold: Bool = false) {
            for _ in 0..<seconds {
                time += 1
                note(schedule.observe(time: time, faceFound: face, quiet: quiet, hold: hold))
            }
        }

        /// Nothing observed for this long: the screen sleeps, or the camera is paused.
        mutating func dark(_ seconds: Double) {
            time += seconds
        }

        /// The clock ticks with no word from the camera.
        mutating func tick(_ seconds: Int) {
            for _ in 0..<seconds {
                time += 1
                note(schedule.advance(to: time))
            }
        }

        /// "In 5 minutes": whether it was allowed.
        mutating func postpone() -> Bool {
            schedule.postpone(at: time)
        }

        mutating func skip() {
            if let event = schedule.skip(at: time) { note([event]) }
        }

        var events: [BreakSchedule.Event] { log.map(\.event) }
        var screenSeconds: Double { schedule.screenSeconds(at: time) }
    }

    private func ended(_ kind: BreakKind, _ ending: BreakOutcome.Ending, sameAbsence: Bool = false) -> BreakSchedule.Event {
        .ended(BreakOutcome(kind: kind, ending: ending, sameAbsence: sameAbsence))
    }

    private let classic = BreakPlan.Preset.classic.plan

    // MARK: The chosen numbers

    @Test("A break comes at the chosen time and lasts the chosen length, plus five seconds to turn away")
    func chosenNumbers() {
        var day = Timeline(BreakPlan(workMinutes: 30, breakSeconds: 40))
        day.watch(30 * 60 - 1)
        #expect(day.events.isEmpty && day.screenSeconds == 1799)
        day.watch(1)
        #expect(day.events == [.due(.short, canPostpone: true)])
        #expect(day.schedule.running?.length == 40 && day.screenSeconds == 0)

        day.watch(44)
        #expect(day.events.count == 1)                      // still running at 44 s
        day.watch(1)
        #expect(day.log.last?.at == 1845)
        #expect(day.events.last == ended(.short, .onTrust))  // the face never left: on trust
        #expect(day.schedule.running == nil)

        day.watch(30 * 60)                                  // and the next one, 30 minutes later
        #expect(day.log.last?.at == 1845 + 1800 && day.events.last == .due(.short, canPostpone: true))
    }

    @Test("A break with no face in view is recorded as away, and the return does not count it twice")
    func seenAway() {
        var day = Timeline(classic)
        day.watch(1200)
        day.watch(3)                                        // reads the banner
        day.watch(22, face: false)                          // looks out of the window, far enough
        #expect(day.events.last == ended(.short, .away))
        day.watch(10, face: false)                          // stays turned away a little longer
        day.watch(60)
        #expect(day.events.count == 2)
        #expect(day.screenSeconds == 59)                    // counted from the return
    }

    @Test("A face lost for two seconds is not a break, at work or during a break")
    func twoSeconds() {
        var day = Timeline(classic)
        day.watch(600)
        day.watch(2, face: false)
        day.watch(598)
        #expect(day.events == [.due(.short, canPostpone: true)])     // on time: the two seconds changed nothing
        #expect(day.log.last?.at == 1200)
        day.watch(10)
        day.watch(2, face: false)
        day.watch(13)
        #expect(day.events.last == ended(.short, .onTrust))          // two seconds away is not "away"
    }

    @Test("A break taken early counts, and the time at the screen starts again from the return")
    func takenEarly() {
        var day = Timeline(classic)
        day.watch(600)
        day.watch(25, face: false)                          // gets a glass of water
        #expect(day.screenSeconds == 0)                     // on a break right now
        day.watch(1)
        #expect(day.events == [ended(.short, .away)])
        #expect(day.schedule.sinceLong == 1)
        day.watch(1199)
        #expect(day.events.count == 1)
        day.watch(1)                                        // 20 minutes after the return
        #expect(day.log.last?.at == 626 + 1200 && day.events.last == .due(.short, canPostpone: true))
    }

    // MARK: The long break

    private let withLong = BreakPlan(workMinutes: 20, breakSeconds: 20, longEvery: 2, longMinutes: 5)

    /// Works up to the long break: two short ones on trust, then the long one falls due.
    private func atLongBreak() -> Timeline {
        var day = Timeline(withLong)
        day.watch(1200 + 25)
        day.watch(1200 + 25)
        #expect(day.schedule.sinceLong == 2 && day.schedule.nextKind == .long)
        day.watch(1200)
        #expect(day.events.last == .due(.long, canPostpone: true))
        return day
    }

    @Test("After N short breaks the next one is long, and the count starts again")
    func everyNth() {
        var day = atLongBreak()
        #expect(day.events.filter { $0 == ended(.short, .onTrust) }.count == 2)
        #expect(day.schedule.running?.length == 300)
        day.watch(300, face: false)                         // five minutes away
        #expect(day.events.last == ended(.long, .away))
        #expect(day.schedule.sinceLong == 0 && day.schedule.nextKind == .short)

        day.watch(120, face: false)                         // stays away two more minutes
        day.watch(1201)                                     // 20 minutes from the first second back
        #expect(day.events.last == .due(.short, canPostpone: true))
        #expect(day.events.filter { $0 == ended(.long, .away) }.count == 1)      // one long break, not two
    }

    @Test("Back in the middle of a long break: the count waits, and leaving again completes it")
    func longBreakInTwoParts() {
        var day = atLongBreak()
        day.watch(120, face: false)
        day.watch(60)                                       // back early
        #expect(day.schedule.running?.away == 120)          // waits; nothing is said
        day.watch(180, face: false)
        #expect(day.events.last == ended(.long, .away))
    }

    @Test("A long break that is not completed is recorded as cut short, and the cycle goes on")
    func longBreakCutShort() {
        var day = atLongBreak()
        let start = day.time
        day.watch(120, face: false)
        day.watch(485)                                      // back for good; 605 s after the start
        #expect(day.events.last == ended(.long, .cutShort))
        #expect(day.time == start + 605)
        #expect(day.screenSeconds == 484)                   // at the screen since the return, not since now
        #expect(day.schedule.sinceLong == 0)
        day.watch(1200 - 484)
        #expect(day.events.last == .due(.short, canPostpone: true))
    }

    @Test("An absence as long as a long break is a long break, whenever it happens")
    func lunch() {
        var day = Timeline(withLong)
        day.watch(1200 + 25)
        #expect(day.schedule.sinceLong == 1)
        day.watch(40 * 60, face: false)
        day.watch(1)
        #expect(day.events.last == ended(.long, .away))
        #expect(day.schedule.sinceLong == 0)
    }

    @Test("Without a long break in the plan, the count never makes one due")
    func noLongBreak() {
        var day = Timeline(classic)
        for _ in 0..<8 { day.watch(1200 + 25) }
        #expect(!day.events.contains(.due(.long, canPostpone: true)))
        day.watch(3600, face: false)
        day.watch(1)
        #expect(day.events.last == ended(.short, .away))    // a long lunch is simply a break
    }

    // MARK: Pauses, sleep, midnight

    @Test("The count to N goes on across a short pause, and starts again after a long one")
    func acrossAPause() {
        var day = Timeline(withLong)
        day.watch(1200 + 25)                                // one short break
        day.watch(300)
        day.dark(120)                                       // camera paused for two minutes
        day.watch(1)
        #expect(day.events.last == ended(.short, .away))    // nobody watched: counted as an absence
        #expect(day.schedule.sinceLong == 2 && day.schedule.nextKind == .long)
        #expect(day.screenSeconds == 0)

        day.watch(300)
        day.dark(3600)                                      // paused for an hour
        day.watch(1)
        #expect(day.events.last == ended(.long, .away))
        #expect(day.schedule.sinceLong == 0)
    }

    @Test("The count to N goes on across midnight; the day's tally starts again")
    func acrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 23:30 UTC, as seconds of the wall clock.
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 23, minute: 30))!
        var day = Timeline(withLong, startingAt: evening.timeIntervalSince1970)
        var tally = BreakTally(day: calendar.startOfDay(for: evening))

        func record(_ day: Timeline, from index: Int, into tally: inout BreakTally) {
            for entry in day.log[index...] {
                guard case .ended(let outcome) = entry.event else { continue }
                let when = Date(timeIntervalSince1970: evening.timeIntervalSince1970 + entry.at)
                tally.record(outcome, dayStart: calendar.startOfDay(for: when))
            }
        }

        day.watch(1200 + 25)                                // a break at 23:50
        record(day, from: 0, into: &tally)
        #expect(tally.taken == 1)
        let before = day.log.count
        day.watch(1200 + 25)                                // a break at 00:10
        record(day, from: before, into: &tally)
        #expect(tally.taken == 1 && tally.day == calendar.startOfDay(for: evening.addingTimeInterval(3600)))
        #expect(day.schedule.sinceLong == 2)                // the schedule does not know about days
        day.watch(1200)
        #expect(day.events.last == .due(.long, canPostpone: true))
    }

    @Test("A screen that sleeps during a break: the break ends away, and a long sleep is one long break")
    func sleepDuringABreak() {
        var day = Timeline(withLong)
        day.watch(1200)
        day.watch(2)
        day.dark(3600)                                      // the lid is closed for an hour
        day.watch(1)
        #expect(day.events.last == ended(.long, .away))     // one break, and a long one
        #expect(day.events.count == 2 && day.schedule.sinceLong == 0)

        // The same hour away, with the break ending by the clock before the screen sleeps.
        var other = Timeline(withLong)
        other.watch(1200)
        other.watch(2, face: false)
        other.tick(23)
        #expect(other.events.last == ended(.short, .away))
        other.dark(3600)
        other.watch(1)
        #expect(other.events.last == ended(.long, .away, sameAbsence: true))
        #expect(other.schedule.sinceLong == 0)
    }

    @Test("A break ends on time when the camera says nothing new, and silence of a second is not absence")
    func clockOnly() {
        var day = Timeline(classic)
        day.watch(1200)
        day.tick(24)
        #expect(day.events.count == 1)
        day.tick(1)
        #expect(day.events.last == ended(.short, .onTrust))

        var other = Timeline(classic)
        other.watch(1200)
        other.watch(1, face: false)
        other.tick(24)                                      // the face was last seen gone
        #expect(other.events.last == ended(.short, .away))
    }

    @Test("A clock that is set back starts a new stretch, never a negative one")
    func clockSetBack() {
        var day = Timeline(classic)
        day.watch(900)
        day.time -= 5000
        day.watch(60)
        #expect(day.events.isEmpty && day.screenSeconds == 59)
    }

    // MARK: Putting off, skipping, quiet

    @Test("A break can be put off for five minutes, once")
    func postponeOnce() {
        var day = Timeline(classic)
        day.watch(1200)
        let allowed = day.postpone()
        #expect(allowed)
        #expect(day.schedule.running == nil)
        day.watch(299)
        #expect(day.events.count == 1 && day.screenSeconds == 1499)
        day.watch(1)
        #expect(day.events.last == .due(.short, canPostpone: false))
        let again = day.postpone()
        #expect(!again)                                      // not a second time
        day.watch(25)
        #expect(day.events.last == ended(.short, .onTrust))
        day.watch(1200)
        #expect(day.events.last == .due(.short, canPostpone: true))   // the next break can be put off again
    }

    @Test("Leaving during the five minutes is the break")
    func postponedThenLeft() {
        var day = Timeline(classic)
        day.watch(1200)
        let allowed = day.postpone()
        #expect(allowed)
        day.watch(60)
        day.watch(30, face: false)
        day.watch(300)
        #expect(day.events.last == ended(.short, .away))
        #expect(day.events.count == 2)                      // and it does not fall due again at once
    }

    @Test("A skipped break is recorded as skipped and still counts towards the long one")
    func skipped() {
        var day = Timeline(withLong)
        day.watch(1200)
        day.skip()
        #expect(day.events.last == ended(.short, .skipped))
        #expect(day.schedule.sinceLong == 1 && day.schedule.running == nil)
        day.watch(1199)
        #expect(day.events.count == 2)
        day.watch(1)
        #expect(day.events.last == .due(.short, canPostpone: true))
    }

    @Test("While breaks are snoozed, one that falls due is passed over and nothing is recorded")
    func quiet() {
        var day = Timeline(classic)
        day.watch(1300, quiet: true)
        #expect(day.events.isEmpty && day.screenSeconds == 100)
        day.watch(1100)
        #expect(day.events == [.due(.short, canPostpone: true)])
    }

    @Test("Held back (a blink break, a timer, the setup), a break that falls due waits, and starts when the hold is over")
    func held() {
        var day = Timeline(classic)
        day.watch(1190)
        day.watch(40, hold: true)                 // due at 1200, in the middle of a blink break
        #expect(day.events.isEmpty && day.screenSeconds == 1230)
        day.watch(1)
        #expect(day.events == [.due(.short, canPostpone: true)])
        #expect(day.log.first?.at == 1231)
    }

    @Test("Switching breaks off forgets the one in progress")
    func stopped() {
        var day = Timeline(classic)
        day.watch(1200)
        day.schedule.stop()
        day.watch(60)
        #expect(day.events.count == 1 && day.schedule.running == nil)
    }

    // MARK: The plan and the tally

    @Test("Numbers outside the ranges are brought back inside")
    func planClamps() {
        let plan = BreakPlan(workMinutes: 0, breakSeconds: 5000, longEvery: 99, longMinutes: -3)
        #expect(plan == BreakPlan(workMinutes: 1, breakSeconds: 300, longEvery: 10, longMinutes: 1))
    }

    @Test("A plan knows which ready-made setting it is")
    func presets() {
        for preset in BreakPlan.Preset.allCases { #expect(preset.plan.preset == preset) }
        #expect(BreakPlan(workMinutes: 20, breakSeconds: 20, longEvery: nil, longMinutes: 12).preset == .classic)
        #expect(BreakPlan(workMinutes: 25, breakSeconds: 20).preset == nil)
        #expect(BreakPlan().preset == .classic)             // the default is the classic rule
    }

    @Test("The tally counts a day, and an absence that grew into a long break once")
    func tally() {
        let today = Date(timeIntervalSince1970: 1_800_230_400)
        var tally = BreakTally(day: today)
        tally.record(BreakOutcome(kind: .short, ending: .onTrust), dayStart: today)
        tally.record(BreakOutcome(kind: .short, ending: .away), dayStart: today)
        tally.record(BreakOutcome(kind: .long, ending: .away, sameAbsence: true), dayStart: today)
        tally.record(BreakOutcome(kind: .short, ending: .skipped), dayStart: today)
        tally.record(BreakOutcome(kind: .long, ending: .cutShort), dayStart: today)
        #expect(tally.taken == 2 && tally.away == 1 && tally.long == 1 && tally.skipped == 1 && tally.cutShort == 1)

        let tomorrow = today.addingTimeInterval(86_400)
        #expect(tally.on(tomorrow) == BreakTally(day: tomorrow))
        tally.record(BreakOutcome(kind: .long, ending: .away, sameAbsence: true), dayStart: tomorrow)
        #expect(tally.taken == 1 && tally.long == 1 && tally.skipped == 0)
    }

    @Test("The time to the next break counts down, and Now starts the break before it is due")
    func nextAndNow() {
        var day = Timeline(BreakPlan(workMinutes: 20, breakSeconds: 20))
        day.watch(14 * 60)
        let untilDue = day.schedule.secondsUntilDue(at: day.time)
        #expect(untilDue == 360.0)
        #expect(day.events.isEmpty)

        // "Now": the break starts at once, cannot be put off, and ends like any other.
        let event = day.schedule.startNow(at: day.time)
        #expect(event == .due(.short, canPostpone: false))
        #expect(day.schedule.secondsUntilDue(at: day.time) == nil, "nothing counts down during a break")
        let second = day.schedule.startNow(at: day.time)
        let putOff = day.postpone()
        #expect(second == nil, "one break at a time")
        #expect(!putOff)
        day.watch(26, face: false)
        #expect(day.events == [.ended(BreakOutcome(kind: .short, ending: .away))])

        // Back at the screen, the count starts again from the full length.
        day.watch(60)
        let left = day.schedule.secondsUntilDue(at: day.time) ?? 0
        #expect(left > 18 * 60 && left <= 20 * 60)

        // Nothing observed yet: nothing to start, nothing to count down to.
        var fresh = BreakSchedule(plan: BreakPlan(workMinutes: 20, breakSeconds: 20))
        let nothing = fresh.startNow(at: 0)
        #expect(nothing == nil && fresh.secondsUntilDue(at: 0) == nil)
    }
}
