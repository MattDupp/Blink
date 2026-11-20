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

    @Published private(set) var notificationsRefused = false
    @Published private(set) var snoozedUntil: Date?
    /// Whole minutes at the screen since your last break (see `PresenceTracker`).
    @Published private(set) var screenMinutes: Int

    /// The banner's "Start Blink Break" button was pressed.
    var onBlinkBreak: () -> Void = {}

    private let preferences: Preferences
    private var policy = ReminderPolicy()
    private var presence = PresenceTracker()
    private let notifier = Notifier()
    private var wanted: AnyCancellable?
    private var prepared = false

    /// `screenMinutes`: what the screenshots start from.
    init(preferences: Preferences, screenMinutes: Int = 0) {
        self.preferences = preferences
        self.screenMinutes = screenMinutes
        notifier.onAction = { [weak self] action in
            switch action {
            case .blinkBreak: self?.onBlinkBreak()
            case .snooze: self?.snooze(minutes: 60)
            }
        }
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
            self?.notificationsRefused = !granted
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

    /// Every update from the camera (`time`: the camera's clock): follows how long you
    /// have been at the screen, and nudges you to look away when it has been long enough.
    func frame(time: Double, faceFound: Bool, now: Date = Date()) {
        presence.frame(time: time, faceFound: faceFound)
        if preferences.breakNudgesOn,
           presence.continuousSeconds(at: time) >= Double(preferences.breakMinutes) * 60 {
            if !policy.isSnoozed(at: now) { notifier.show(.screenBreak(minutes: preferences.breakMinutes)) }
            // The camera cannot see where you look: once told, the count starts again.
            presence.restart(at: time)
        }
        let minutes = Int(presence.continuousSeconds(at: time) / 60)
        if minutes != screenMinutes { screenMinutes = minutes }
    }
}
