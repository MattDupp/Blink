import SwiftUI
import AppKit
import BlinkCore

/// Runs the look-away breaks: feeds the rules, shows the banner when a break starts, and
/// plays a sound when it ends.
///
/// The rules are `BreakSchedule` (in BlinkCore, tested on hand-written timelines). This
/// class adds what a rule cannot have: the wall clock, a timer, the banner, the sound and
/// the stored tally. Not to be confused with the blink break (`BlinkBreakController`),
/// which is an exercise in its own window.
///
/// WHY A SOUND AND NO COUNTDOWN. A break is for looking away from the screen. A countdown
/// on the screen asks you to look at it. So the break starts by itself, and a sound says
/// when it is over.
@MainActor
final class ScreenBreakController: ObservableObject {

    /// The break in progress, as the windows show it.
    struct Current: Equatable {
        var kind: BreakKind
        /// Its length, in seconds.
        var seconds: Int
        /// Whole seconds with no face in view so far.
        var awaySeconds = 0
        var canPostpone = true
    }

    /// Whole minutes at the screen since your last break.
    @Published private(set) var screenMinutes: Int
    @Published private(set) var current: Current?
    /// The next break to fall due is the long one.
    @Published private(set) var nextIsLong = false
    /// Whole minutes until the next break falls due. Nil when nothing counts down.
    @Published private(set) var minutesUntilNext: Int?
    @Published private var stored: BreakTally

    /// A break starts: show its banner (title, text, whether it can still be put off).
    var announce: (String, String, Bool) -> Void = { _, _, _ in }
    /// A break is over: its banner has nothing left to say.
    var withdraw: () -> Void = {}
    /// The sound that says a break is over (`Notifier.breakOver`). Not called when the
    /// end sound is switched off in Settings, nor while "Quiet" is on.
    var playEnd: () -> Void = { NSSound(named: "Glass")?.play() }
    /// "Quiet" is on at this moment: a break that falls due is passed over, and one that
    /// ends makes no sound.
    var isSnoozed: (Date) -> Bool = { _ in false }
    /// A blink break, a routine's timer or the setup is under way: a break that falls due
    /// waits for it to be over (`BannerGate`).
    var isHeld: () -> Bool = { false }
    /// A break's banner was shown: the gate's two minutes start.
    var onAnnounced: (Date) -> Void = { _ in }

    private let preferences: Preferences
    private var schedule: BreakSchedule
    private var timer: Timer?
    /// The break in progress was announced, so its end is worth a sound.
    private var announced = false

    /// `screenMinutes`, `current`, `tally`: what the screenshots start from.
    init(preferences: Preferences, screenMinutes: Int = 0, current: Current? = nil, tally: BreakTally? = nil) {
        self.preferences = preferences
        self.screenMinutes = screenMinutes
        self.current = current
        // (For the screenshots, which state the minutes: the schedule itself is empty.)
        minutesUntilNext = screenMinutes > 0 ? max(0, preferences.breakPlan.workMinutes - screenMinutes) : nil
        schedule = BreakSchedule(plan: preferences.breakPlan)
        stored = tally ?? preferences.breakTally ?? BreakTally(day: .distantPast)
    }

    /// Puts the controller in a situation, for the screenshots.
    func show(current: Current?, nextIsLong: Bool = false, tally: BreakTally) {
        self.current = current
        self.nextIsLong = nextIsLong
        stored = tally
    }

    /// Today's breaks. Yesterday's numbers are never shown as today's.
    func tally(now: Date) -> BreakTally {
        stored.on(Calendar.current.startOfDay(for: now))
    }

    /// Every update from the camera: was a face in view?
    func frame(faceFound: Bool, now: Date = Date()) {
        let wanted = preferences.breakNudgesOn
        if !wanted, schedule.running != nil {      // switched off in the middle of a break
            schedule.stop()
            ended()
        }
        schedule.plan = preferences.breakPlan
        let events = schedule.observe(time: now.timeIntervalSinceReferenceDate, faceFound: faceFound,
                                      quiet: !wanted || isSnoozed(now), hold: isHeld())
        handle(events, now: now)
    }

    /// Once a second during a break: it must end on time even when no frame arrives
    /// (the camera sends few updates while nobody is in view, and none while it sleeps).
    func tick(now: Date = Date()) {
        handle(schedule.advance(to: now.timeIntervalSinceReferenceDate), now: now)
    }

    /// A break falls due within `seconds`: the other banners let it go first.
    func dueWithin(_ seconds: Double, now: Date = Date()) -> Bool {
        guard preferences.breakNudgesOn, schedule.running == nil else { return false }
        return schedule.screenSeconds(at: now.timeIntervalSinceReferenceDate) >= Double(schedule.plan.workMinutes) * 60 - seconds
    }

    /// "Quiet" was just chosen: a break in progress ends without a sound or a mark.
    func quieted() {
        guard schedule.running != nil else { return }
        schedule.stop()
        ended()
        publish(now: Date())
    }

    /// "In 5 Minutes": once per break.
    func postpone(now: Date = Date()) {
        guard schedule.postpone(at: now.timeIntervalSinceReferenceDate) else { return }
        ended()
        publish(now: now)
    }

    /// "Now", in the panel: the next break starts before it is due.
    func startNow(now: Date = Date()) {
        guard preferences.breakNudgesOn, let event = schedule.startNow(at: now.timeIntervalSinceReferenceDate) else { return }
        handle([event], now: now)
    }

    /// "Skip".
    func skip(now: Date = Date()) {
        guard let event = schedule.skip(at: now.timeIntervalSinceReferenceDate) else { return }
        handle([event], now: now)
    }

    private func handle(_ events: [BreakSchedule.Event], now: Date) {
        for event in events {
            switch event {
            case .due(let kind, let canPostpone):
                announced = true
                Log.app.notice("Look-away break starts: \(kind.rawValue, privacy: .public), \(Int(self.schedule.running?.length ?? 0)) s")
                let minutes = max(1, Int(schedule.plan.workMinutes))
                announce(BreakWords.bannerTitle(kind, plan: schedule.plan),
                         BreakWords.bannerBody(kind, screenMinutes: minutes), canPostpone)
                onAnnounced(now)
                startTimer()
            case .ended(let outcome):
                // An absence nobody announced (you simply left) ends without a sound.
                if announced {
                    if (outcome.ending == .away || outcome.ending == .onTrust) && !isSnoozed(now) && preferences.breakEndSound {
                        playEnd()
                    }
                    ended()
                }
                Log.app.notice("Break ended: \(outcome.kind.rawValue, privacy: .public), \(String(describing: outcome.ending), privacy: .public)")
                stored.record(outcome, dayStart: Calendar.current.startOfDay(for: now))
                preferences.breakTally = stored
            }
        }
        publish(now: now)
    }

    /// The announced break is no longer running.
    private func ended() {
        announced = false
        timer?.invalidate()
        timer = nil
        withdraw()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Publishes only what changed: the windows are redrawn by every assignment.
    private func publish(now: Date) {
        let minutes = Int(schedule.screenSeconds(at: now.timeIntervalSinceReferenceDate) / 60)
        if minutes != screenMinutes { screenMinutes = minutes }
        let running = schedule.running.map {
            Current(kind: $0.kind, seconds: Int($0.length), awaySeconds: Int($0.away), canPostpone: $0.canPostpone)
        }
        if running != current { current = running }
        let long = schedule.nextKind == .long
        if long != nextIsLong { nextIsLong = long }
        let next = schedule.secondsUntilDue(at: now.timeIntervalSinceReferenceDate).map { Int(($0 / 60).rounded(.up)) }
        if next != minutesUntilNext { minutesUntilNext = next }
    }
}
