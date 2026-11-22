import SwiftUI
import Combine
import BlinkCore

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

    /// What you are in the middle of (a blink break, a timer, the setup): asked by the
    /// gate before every banner. The model says.
    var busy: () -> BannerGate.Busy = { .free }

    private let preferences: Preferences
    private var policy = ReminderPolicy()
    /// The one gate every banner asks (`BannerGate`): the breaks and the blink reminder
    /// here, the routines through `mayShow`.
    private var gate = BannerGate()
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
            }
        }
        breaks.announce = { [weak self] title, body, canPostpone in
            self?.notifier.show(.screenBreak(title: title, body: body, canPostpone: canPostpone))
        }
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
        wanted = preferences.$remindersOn.combineLatest(preferences.$breakNudgesOn)
            .dropFirst()
            .sink { [weak self] reminders, nudges in
                if reminders || nudges { self?.askForNotifications() }
            }
    }

    /// Your rate over the last 3 minutes while it is under the limit, else nil.
    func lowRate(in minutes: [MinuteRecord], now: Date = Date()) -> Double? {
        policy.lowRate(records: minutes, threshold: Double(preferences.limit), now: now)
    }

    /// The camera runs: ask macOS for the right to show notifications, if any are wanted.
    func prepare() {
        prepared = true
        if preferences.remindersOn || preferences.breakNudgesOn { askForNotifications() }
    }

    private func askForNotifications() {
        guard prepared else { return }      // not before the Welcome window has been read
        notifier.requestPermission { [weak self] granted in
            self?.notifications = granted ? .allowed : .refused
        }
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
        guard let due = policy.reminder(rate: rate, threshold: Double(preferences.limit), now: now, allowed: allowed),
              let rate else { return }
        gate.shown(at: now)
        notifier.show(.lowRate(recent: rate, sound: due.sound))
    }

    /// A blink break was finished: the reminder that asked for it is answered. Its banner
    /// is taken back, and none comes for 20 minutes (`ReminderPolicy.blinkBreakDone`).
    func blinkBreakDone(now: Date = Date()) {
        policy.blinkBreakDone(at: now)
        notifier.withdrawLowRate()
    }

    /// Every update from the camera: the look-away breaks follow who is at the screen.
    func frame(faceFound: Bool, now: Date = Date()) {
        breaks.frame(faceFound: faceFound, now: now)
    }
}
