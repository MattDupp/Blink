import Foundation
import Testing
import BlinkCore
@testable import BlinkMonitor

/// The look-away breaks as the app runs them: stored choices, the words, and the
/// controller fed by hand, with no banner and no sound.
@MainActor
@Suite("Look-away breaks in the app", .serialized)
struct BreakTests {

    /// A settings store of this suite's own, emptied: other suites use `.temporary()`.
    private func store() -> UserDefaults {
        let name = "local.blinkmonitor.break-tests"
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    /// What the controller asked for, written down in place of banners and sounds.
    private final class Heard {
        var banners: [(title: String, body: String, canPostpone: Bool)] = []
        var withdrawn = 0
        var endSounds = 0
    }

    private func controller(_ preferences: Preferences) -> (ScreenBreakController, Heard) {
        let heard = Heard()
        let breaks = ScreenBreakController(preferences: preferences)
        breaks.announce = { heard.banners.append(($0, $1, $2)) }
        breaks.withdraw = { heard.withdrawn += 1 }
        breaks.playEnd = { heard.endSounds += 1 }
        return (breaks, heard)
    }

    /// 10:00 on a Friday, local time.
    private var morning: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
    }

    /// One update a second from the camera, from `from` for `seconds` seconds.
    private func watch(_ breaks: ScreenBreakController, from: Date, seconds: Int, face: Bool = true) -> Date {
        for second in 1...seconds { breaks.frame(faceFound: face, now: from.addingTimeInterval(Double(second))) }
        return from.addingTimeInterval(Double(seconds))
    }

    // MARK: Stored choices

    @Test("Someone who chose a time before the other numbers existed keeps it, with the classic rest")
    func olderSettingsKept() {
        let defaults = store()
        defaults.set(true, forKey: "breakNudgesOn")
        defaults.set(45, forKey: "breakMinutes")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.breakNudgesOn)
        #expect(preferences.breakPlan == BreakPlan(workMinutes: 45, breakSeconds: 20, longEvery: nil))
    }

    @Test("A new install starts from the classic 20-20-20, and the plan is stored number by number")
    func planStored() {
        let defaults = store()
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.breakPlan.preset == .classic)
        preferences.breakPlan = BreakPlan(workMinutes: 25, breakSeconds: 40, longEvery: 3, longMinutes: 7)
        #expect(Preferences(defaults: defaults).breakPlan == BreakPlan(workMinutes: 25, breakSeconds: 40, longEvery: 3, longMinutes: 7))

        // Switching the long break off keeps its numbers for the day it is switched on again.
        preferences.breakPlan = BreakPlan.Preset.classic.plan
        #expect(preferences.breakPlan.longEvery == nil && preferences.longBreakEvery == 3 && preferences.longBreakMinutes == 7)
    }

    // MARK: The words

    @Test("Every text names the chosen numbers: nothing says 20 seconds when the break is 40")
    func wordsFollowThePlan() {
        let plan = BreakPlan(workMinutes: 25, breakSeconds: 40, longEvery: 3, longMinutes: 7)
        let texts = [BreakWords.bannerTitle(.short, plan: plan), BreakWords.bannerBody(.short, screenMinutes: 25),
                     BreakWords.bannerTitle(.long, plan: plan), BreakWords.bannerBody(.long, screenMinutes: 25),
                     BreakWords.summary(plan), BreakWords.running(.init(kind: .short, seconds: 40)),
                     BreakWords.running(.init(kind: .long, seconds: 420, awaySeconds: 130))]
        for text in texts { #expect(!text.contains("20"), "\(text)") }
        #expect(texts[0] == "Look far away for 40 seconds")
        #expect(texts[2] == "Long break: leave the screen for 7 minutes")
        #expect(texts[4] == "Every 25 minutes at the screen, look far away for 40 seconds. After 3 of these, leave the screen for 7 minutes.")
        #expect(texts[6] == "Long break: 2 of 7 min away from the screen.")
    }

    @Test("Lengths are said the way people say them")
    func lengths() {
        #expect(BreakWords.length(seconds: 40) == "40 seconds")
        #expect(BreakWords.length(seconds: 60) == "1 minute")
        #expect(BreakWords.length(seconds: 90) == "1 min 30 s")
        #expect(BreakWords.length(minutes: 5) == "5 minutes")
    }

    @Test("The tally says what was seen and what was not, and nothing before the first break")
    func tallyWords() {
        let today = Calendar.current.startOfDay(for: morning)
        var tally = BreakTally(day: today)
        #expect(BreakWords.tally(tally) == nil)
        tally.record(BreakOutcome(kind: .short, ending: .onTrust), dayStart: today)
        #expect(BreakWords.tally(tally) == "Breaks today: 1")
        tally.record(BreakOutcome(kind: .long, ending: .away), dayStart: today)
        tally.record(BreakOutcome(kind: .short, ending: .skipped), dayStart: today)
        tally.record(BreakOutcome(kind: .long, ending: .cutShort), dayStart: today)
        #expect(BreakWords.tally(tally) == "Breaks today: 2 (1 away from the screen, 1 long), 1 skipped, 1 cut short")
    }

    @Test("The panel says when the next break comes, and of today only the breaks taken")
    func panelWords() {
        #expect(BreakWords.atTheScreen(minutes: 14, next: 6, nextIsLong: false) == "14 min at the screen. Next look-away break in 6 min.")
        #expect(BreakWords.atTheScreen(minutes: 20, next: 0, nextIsLong: true) == "20 min at the screen. The long break is due.")
        let today = Calendar.current.startOfDay(for: morning)
        var tally = BreakTally(day: today)
        tally.record(BreakOutcome(kind: .short, ending: .skipped), dayStart: today)
        #expect(BreakWords.takenToday(tally) == nil, "a skipped break is not shown all day")
        tally.record(BreakOutcome(kind: .short, ending: .onTrust), dayStart: today)
        #expect(BreakWords.takenToday(tally) == "Look-away breaks today: 1")
    }

    @Test("Now starts the break at once, with its banner and without the Later button")
    func startNow() {
        let preferences = Preferences(defaults: store())
        preferences.breakNudgesOn = true
        preferences.breakPlan = BreakPlan(workMinutes: 20, breakSeconds: 20)
        let (breaks, heard) = controller(preferences)
        breaks.frame(faceFound: true, now: morning)
        let now = watch(breaks, from: morning, seconds: 300)
        #expect(breaks.minutesUntilNext == 15 && heard.banners.isEmpty)
        breaks.startNow(now: now)
        #expect(breaks.current?.kind == .short && breaks.current?.canPostpone == false)
        #expect(heard.banners.count == 1 && !heard.banners[0].canPostpone && breaks.minutesUntilNext == nil)
    }

    // MARK: The controller

    @Test("With the settings changed, the break comes at the chosen time, lasts the chosen length, and every Nth is long")
    func chosenBreaks() {
        let preferences = Preferences(defaults: store())
        preferences.breakNudgesOn = true
        preferences.breakPlan = BreakPlan(workMinutes: 2, breakSeconds: 40, longEvery: 2, longMinutes: 1)
        let (breaks, heard) = controller(preferences)

        breaks.frame(faceFound: true, now: morning)
        var now = watch(breaks, from: morning, seconds: 119)
        #expect(heard.banners.isEmpty && breaks.screenMinutes == 1)
        now = watch(breaks, from: now, seconds: 1)
        #expect(heard.banners.count == 1 && heard.banners[0].title == "Look far away for 40 seconds")
        #expect(heard.banners[0].canPostpone)
        #expect(breaks.current == .init(kind: .short, seconds: 40))

        now = watch(breaks, from: now, seconds: 44, face: false)
        #expect(heard.endSounds == 0)
        now = watch(breaks, from: now, seconds: 1, face: false)       // 40 s and the 5 to turn away
        #expect(heard.endSounds == 1 && heard.withdrawn == 1 && breaks.current == nil)
        #expect(breaks.tally(now: now).taken == 1 && breaks.tally(now: now).away == 1)

        now = watch(breaks, from: now, seconds: 121 + 45)             // the second, with the face in view
        #expect(heard.endSounds == 2 && breaks.tally(now: now).taken == 2 && breaks.tally(now: now).away == 1)
        #expect(breaks.nextIsLong)

        now = watch(breaks, from: now, seconds: 120)
        #expect(heard.banners.count == 3 && heard.banners[2].title == "Long break: leave the screen for 1 minute")
        now = watch(breaks, from: now, seconds: 60, face: false)
        #expect(heard.endSounds == 3 && breaks.tally(now: now).long == 1 && !breaks.nextIsLong)

        // The tally is stored: it is there after a relaunch, and gone the next day.
        #expect(preferences.breakTally?.taken == 3)
        #expect(breaks.tally(now: now.addingTimeInterval(86_400)).taken == 0)
    }

    @Test("A break ends on time by the clock alone, when the camera sends nothing")
    func endsWithoutFrames() {
        let preferences = Preferences(defaults: store())
        preferences.breakNudgesOn = true
        preferences.breakPlan = BreakPlan(workMinutes: 1, breakSeconds: 10)
        let (breaks, heard) = controller(preferences)
        breaks.frame(faceFound: true, now: morning)
        let now = watch(breaks, from: morning, seconds: 60)
        for second in 1...15 { breaks.tick(now: now.addingTimeInterval(Double(second))) }
        #expect(heard.endSounds == 1 && breaks.current == nil)
    }

    @Test("Skip and In 5 Minutes take the banner away without the sound of a finished break")
    func skipAndPostpone() {
        let preferences = Preferences(defaults: store())
        preferences.breakNudgesOn = true
        preferences.breakPlan = BreakPlan(workMinutes: 1, breakSeconds: 20)
        let (breaks, heard) = controller(preferences)
        breaks.frame(faceFound: true, now: morning)
        var now = watch(breaks, from: morning, seconds: 60)
        breaks.postpone(now: now)
        #expect(breaks.current == nil && heard.withdrawn == 1 && heard.endSounds == 0)
        now = watch(breaks, from: now, seconds: 300)
        #expect(heard.banners.count == 2 && !heard.banners[1].canPostpone)
        breaks.skip(now: now)
        #expect(breaks.current == nil && heard.withdrawn == 2 && heard.endSounds == 0)
        #expect(breaks.tally(now: now).skipped == 1 && breaks.tally(now: now).taken == 0)
    }

    @Test("Switched off or snoozed, nothing is shown; leaving on your own makes no sound")
    func quiet() {
        let preferences = Preferences(defaults: store())
        preferences.breakPlan = BreakPlan(workMinutes: 2, breakSeconds: 20)
        let (breaks, heard) = controller(preferences)
        breaks.frame(faceFound: true, now: morning)
        var now = watch(breaks, from: morning, seconds: 200)          // breaks are off
        #expect(heard.banners.isEmpty)

        preferences.breakNudgesOn = true
        breaks.isSnoozed = { _ in true }
        now = watch(breaks, from: now, seconds: 200)
        #expect(heard.banners.isEmpty)

        breaks.isSnoozed = { _ in false }
        now = watch(breaks, from: now, seconds: 30)
        now = watch(breaks, from: now, seconds: 30, face: false)      // gets up before any break is due
        now = watch(breaks, from: now, seconds: 5)
        #expect(heard.banners.isEmpty && heard.endSounds == 0)
        #expect(breaks.tally(now: now).taken == 1 && breaks.tally(now: now).away == 1)

        now = watch(breaks, from: now, seconds: 120)
        #expect(heard.banners.count == 1)
        preferences.breakNudgesOn = false                             // switched off in the middle of a break
        now = watch(breaks, from: now, seconds: 2)
        #expect(breaks.current == nil && heard.withdrawn == 1 && heard.endSounds == 0)
    }

    @Test("The sound at the end of a break can be switched off; the break is counted all the same")
    func endSoundOff() {
        let preferences = Preferences(defaults: store())
        preferences.breakPlan = BreakPlan(workMinutes: 2, breakSeconds: 20)
        preferences.breakNudgesOn = true
        #expect(preferences.breakStartSound && preferences.breakEndSound)      // both on unless you say otherwise
        preferences.breakEndSound = false
        let (breaks, heard) = controller(preferences)
        breaks.frame(faceFound: true, now: morning)
        var now = watch(breaks, from: morning, seconds: 121)
        #expect(heard.banners.count == 1)
        now = watch(breaks, from: now, seconds: 40)
        #expect(breaks.current == nil && heard.endSounds == 0)
        #expect(breaks.tally(now: now).taken == 1)
    }

    @Test("Quiet holds the blink reminder and the routines, is remembered, and ends by itself or by hand")
    func quietForAWhile() {
        let defaults = store()
        let reminders = ReminderController(preferences: Preferences(defaults: defaults))
        #expect(reminders.mayShowRoutineBanner(now: morning) && !reminders.isQuiet(now: morning))
        reminders.setQuiet(.oneHour, now: morning)
        #expect(reminders.isQuiet(now: morning.addingTimeInterval(1800)))
        #expect(!reminders.mayShowRoutineBanner(now: morning.addingTimeInterval(1800)))
        #expect(reminders.mayShowRoutineBanner(now: morning.addingTimeInterval(3601)))
        #expect(reminders.snoozedUntil == morning.addingTimeInterval(3600))
        // Remembered: it is in the store a relaunch reads.
        #expect(Preferences(defaults: defaults).quietUntil == morning.addingTimeInterval(3600))
        reminders.setQuiet(until: nil)
        #expect(reminders.mayShowRoutineBanner(now: morning.addingTimeInterval(60)) && reminders.snoozedUntil == nil)
        #expect(Preferences(defaults: defaults).quietUntil == nil)

        // In the middle of a blink break, a timer or the setup, a routine's banner waits.
        reminders.busy = { BannerGate.Busy(blinkBreak: true) }
        #expect(!reminders.mayShowRoutineBanner(now: morning))
        reminders.busy = { .free }
        // Two minutes after any banner.
        reminders.routineBannerShown(now: morning)
        #expect(!reminders.mayShowRoutineBanner(now: morning.addingTimeInterval(60)))
        #expect(reminders.mayShowRoutineBanner(now: morning.addingTimeInterval(120)))
    }

    @Test("In the demo the made-up person looks away during a break: no face in view")
    func demoLooksAway() {
        var eyes = DemoEyes()
        #expect(eyes.reading(at: 1).faceFound)
        eyes.away = true
        #expect(!eyes.reading(at: 2).faceFound)
        eyes.away = false
        #expect(eyes.reading(at: 3).faceFound)
    }
}
