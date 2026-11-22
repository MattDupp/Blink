import SwiftUI
import Combine
import BlinkCore
import UserNotifications

/// Everything that taps you on the shoulder: the "you blink too little" reminder and the
/// "look away for a moment" nudge.
///
/// "Are you blinking too little right now?" is NOT stored here: it is computed from the
/// minutes and the limit each time it is asked (`lowRate`), so it is right the moment
/// either of them changes.
@MainActor
final class ReminderController: ObservableObject {

    /// What macOS answered about notifications. `unknown`: not asked yet, or the
    /// question is still on screen (or waiting in Notification Centre).
    enum Notifications {
        case unknown, allowed, refused
    }

    @Published private(set) var notifications = Notifications.unknown
    var notificationsRefused: Bool { notifications == .refused }
    @Published private(set) var snoozedUntil: Date?
    /// The look-away breaks. Its changes are passed on, so a view that watches the
    /// reminders is redrawn by them too.
    let breaks: ScreenBreakController
    /// Whole minutes at the screen since your last break.
    var screenMinutes: Int { breaks.screenMinutes }

    /// The banner's "Start Blink Break" button was pressed.
    var onBlinkBreak: () -> Void = {}
    /// A banner itself was clicked: show the panel.
    var onOpenPanel: () -> Void = {}
    /// A break started and no banner could say so (no right to notify, as in the demo).
    var onBreakUnannounced: () -> Void = {}
    /// The blink reminder was shown: written to the break log.
    var onBlinkReminder: (Date) -> Void = { _ in }

    /// What you are in the middle of (a blink break, a timer, the setup): asked by the
    /// gate before every banner. The model says.
    var busy: () -> BannerGate.Busy = { .free }

    private let preferences: Preferences
    private var policy = ReminderPolicy()
    /// The one gate every banner asks (`BannerGate`): the breaks and the blink reminder
    /// here, the routines through `mayShow`.
    ///
    /// The working hours are read from the preferences each time the gate is asked, so a
    /// change in Settings holds from the next question on, with nothing to keep in step.
    private var gate: BannerGate {
        get {
            var gate = storedGate
            gate.hours = preferences.workingHours
            return gate
        }
        set { storedGate = newValue }
    }
    private var storedGate = BannerGate()
    /// The app's one `Notifier`: the routines show their banners through it too.
    let notifier = Notifier()
    private var wanted: AnyCancellable?
    private var breaksChanged: AnyCancellable?
    private var prepared = false

    /// `screenMinutes`, `notifications`: what the screenshots start from.
    init(preferences: Preferences, screenMinutes: Int = 0, notifications: Notifications = .unknown) {
        self.preferences = preferences
        self.notifications = notifications
        breaks = ScreenBreakController(preferences: preferences, screenMinutes: screenMinutes)
        notifier.onAction = { [weak self] action in
            switch action {
            case .blinkBreak: self?.onBlinkBreak()
            case .snooze: self?.snooze(minutes: 60)
            case .postponeBreak: self?.breaks.postpone()
            case .skipBreak: self?.breaks.skip()
            case .openPanel: self?.onOpenPanel()
            }
        }
        breaks.announce = { [weak self] title, body, canPostpone in
            self?.notifier.show(.screenBreak(title: title, body: body, canPostpone: canPostpone,
                                             sound: preferences.breakStartSound))
            if self?.notifier.allowed == false { self?.onBreakUnannounced() }
        }
        breaks.playEnd = { [weak self] sound in self?.notifier.breakOver(sound: sound) }
        breaks.tell = { [weak self] title, body in self?.notifier.breakNote(title: title, body: body) }
        breaks.withdraw = { [weak self] in self?.notifier.withdrawScreenBreak() }
        breaks.isSnoozed = { [weak self] now in self?.gate.isQuiet(at: now) ?? false }
        // A break does not wait for the gate's two minutes: it goes first, and the other
        // kinds stay away when one is about to fall due (`soon`). It waits only for what
        // you are in the middle of.
        breaks.isHeld = { [weak self] in self?.busy().holds(.screenBreak) ?? false }
        breaks.onAnnounced = { [weak self] now in self?.gate.shown(at: now) }
        // Quiet survives a relaunch.
        if let until = preferences.quietUntil, until > Date() {
            gate.quiet(until: until)
            snoozedUntil = until
        }
        breaksChanged = breaks.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        // Switching a nudge on in Settings is the moment to ask macOS for notifications.
        wanted = preferences.$remindersOn.combineLatest(preferences.$breakNudgesOn, preferences.$summaryOn)
            .dropFirst()
            .sink { [weak self] reminders, nudges, summary in
                if reminders || nudges || summary { self?.askForNotifications() }
            }
    }

    /// Your rate over the last 3 minutes while it is under the limit, else nil.
    func lowRate(in minutes: [MinuteRecord], now: Date = Date()) -> Double? {
        policy.lowRate(records: minutes, threshold: Double(preferences.limit), now: now)
    }

    /// The camera runs: ask macOS for the right to show notifications, if any are wanted.
    func prepare() {
        prepared = true
        if preferences.remindersOn || preferences.breakNudgesOn || preferences.summaryOn { askForNotifications() }
    }

    private func askForNotifications() {
        guard prepared else { return }      // not before the Welcome window has been read
        notifier.requestPermission { [weak self] granted in
            self?.notifications = granted ? .allowed : .refused
        }
    }

    /// Puts the answer in a state, for the screenshots.
    func state(notifications: Notifications) {
        self.notifications = notifications
    }

    /// Reads what macOS says now, without asking anything. The answer can change behind
    /// the app's back, in System Settings: whoever shows it reads it again when it opens.
    func rereadNotifications() {
        guard prepared else { return }
        notifier.readPermission { [weak self] allowed in
            guard let self, let allowed else { return }
            let new: Notifications = allowed ? .allowed : .refused
            if self.notifications != new { self.notifications = new }
        }
    }

    /// Shows the reminder now, as it will look. Nobody should have to blink too little
    /// for three minutes to find out whether banners are allowed.
    func sendTest() {
        notifier.requestPermission { [weak self] granted in
            self?.notifications = granted ? .allowed : .refused
            self?.notifier.show(.lowRateTest)
        }
    }

    /// The same for a look-away break, with the numbers chosen in Settings.
    func sendBreakTest() {
        let plan = preferences.breakPlan
        notifier.requestPermission { [weak self] granted in
            self?.notifications = granted ? .allowed : .refused
            self?.notifier.show(.screenBreakTest(title: BreakWords.bannerTitle(.short, plan: plan),
                                                 body: BreakWords.bannerBody(.short, endSound: self?.preferences.breakEndSound ?? true)))
        }
    }

    /// QUIET: no banner and no sound of any kind before `until` (nil: over now). The blink
    /// reminder, the look-away breaks and the routines all ask the same gate. Counting
    /// goes on, and the choice is remembered across a relaunch.
    func setQuiet(until: Date?) {
        gate.quiet(until: until)
        preferences.quietUntil = until
        snoozedUntil = until
        if until != nil { breaks.quieted() }
    }

    func setQuiet(_ length: BannerGate.QuietLength, now: Date = Date()) {
        setQuiet(until: length.end(from: now))
    }

    /// The banner's "Snooze 1 Hour": the same Quiet, for an hour.
    func snooze(minutes: Int?, now: Date = Date()) {
        setQuiet(until: minutes.map { now.addingTimeInterval(Double($0) * 60) })
    }

    func isQuiet(now: Date = Date()) -> Bool { gate.isQuiet(at: now) }

    /// Why it is quiet now, and until when: the Quiet chosen in the panel, or the time
    /// outside the working hours set in Settings. Nil: banners may show.
    func quietReason(now: Date = Date()) -> BannerGate.QuietReason? { gate.quietReason(at: now) }

    /// A routine asks whether its banner may show now, and says when it did.
    func mayShowRoutineBanner(now: Date = Date()) -> Bool {
        gate.mayShow(.routine, busy: busy(), soon: soon(now: now), now: now)
    }

    func routineBannerShown(now: Date = Date()) {
        gate.shown(at: now)
    }

    /// A look-away break is about to fall due: it goes first.
    private func soon(now: Date) -> Set<BannerGate.Kind> {
        breaks.dueWithin(BannerGate.gapSeconds, now: now) ? [.screenBreak] : []
    }

    /// A minute just ended: show a reminder if one is due.
    func minuteEnded(minutes: [MinuteRecord], now: Date = Date()) {
        if let snoozedUntil, now >= snoozedUntil {
            self.snoozedUntil = nil
            preferences.quietUntil = nil
        }
        // The policy is asked every minute, low or not: it is how it learns that the rate
        // came back above the limit, which ends its back-off.
        let rate = policy.recentRate(records: minutes, now: now)
        let allowed = preferences.remindersOn && gate.mayShow(.blink, busy: busy(), soon: soon(now: now), now: now)
        // A banner that stopped being true is taken back: "Under your limit" sat
        // in Notification Centre for hours after the rate had come back.
        if let rate, rate >= Double(preferences.limit) { notifier.withdrawLowRate() }
        guard let due = policy.reminder(rate: rate, threshold: Double(preferences.limit), now: now, allowed: allowed) else { return }
        gate.shown(at: now)
        notifier.show(.lowRate(limit: preferences.limit, sound: due.sound))
        onBlinkReminder(now)
    }

    /// The optional summary of the day: once, at the first minute that ends from the
    /// chosen hour on, when the gate lets a banner through. It is asked after the blink
    /// reminder and gives way to it and to a break about to fall due. A day with nothing
    /// counted says nothing, and is not asked again.
    func summaryIfDue(minutes: [MinuteRecord], now: Date = Date(), calendar: Calendar = .current) {
        guard preferences.summaryOn,
              SummarySchedule.isDue(now: now, hour: preferences.summaryHour, lastShown: preferences.summaryShownDay, calendar: calendar),
              gate.mayShow(.summary, busy: busy(), soon: soon(now: now), now: now) else { return }
        let digest = DayDigest(records: minutes, limit: Double(preferences.limit), breaksTaken: breaks.tally(now: now).taken,
                               now: now, calendar: calendar)
        preferences.summaryShownDay = SummarySchedule.key(of: now, calendar: calendar)
        guard let body = SummaryWords.body(digest, limit: preferences.limit) else { return }
        gate.shown(at: now)
        let content = UNMutableNotificationContent()
        content.title = SummaryWords.title
        content.body = body
        content.sound = nil      // it reports, it does not call
        notifier.show(content, identifier: SummaryWords.identifier)
        onSummary(body)
        Log.app.notice("Summary of the day shown")
    }

    /// The summary was shown, with these words (the tests read them).
    var onSummary: (String) -> Void = { _ in }

    /// A blink break was finished: the reminder that asked for it is answered. Its banner
    /// is taken back, and none comes for 20 minutes (`ReminderPolicy.blinkBreakDone`).
    func blinkBreakDone(now: Date = Date()) {
        policy.blinkBreakDone(at: now)
        notifier.withdrawLowRate()
    }

    /// The camera was paused, or the Mac goes to sleep: what the blink banner says is no
    /// longer about now.
    func stoppedLooking() {
        notifier.withdrawLowRate()
    }

    /// Every update from the camera: the look-away breaks follow who is at the screen.
    func frame(faceFound: Bool, now: Date = Date()) {
        breaks.frame(faceFound: faceFound, now: now)
    }
}
