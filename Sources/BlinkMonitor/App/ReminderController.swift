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

    private let preferences: Preferences
    private var policy = ReminderPolicy()
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
        breaks.isSnoozed = { [weak self] now in self?.policy.isSnoozed(at: now) ?? false }
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
            self?.notifier.show(.lowRate(recent: 6))
        }
    }

    /// No reminder and no nudge for this long (nil: they are back now).
    func snooze(minutes: Int?, now: Date = Date()) {
        let until = minutes.map { now.addingTimeInterval(Double($0) * 60) }
        policy.snooze(until: until)
        snoozedUntil = until
    }

    /// A minute just ended: show a reminder if one is due.
    func minuteEnded(minutes: [MinuteRecord], now: Date = Date()) {
        if let snoozedUntil, now >= snoozedUntil { self.snoozedUntil = nil }
        guard preferences.remindersOn, let low = lowRate(in: minutes, now: now),
              policy.reminderDue(rate: low, threshold: Double(preferences.limit), now: now) else { return }
        notifier.show(.lowRate(recent: low))
    }

    /// Every update from the camera: the look-away breaks follow who is at the screen.
    func frame(faceFound: Bool, now: Date = Date()) {
        breaks.frame(faceFound: faceFound, now: now)
    }
}
