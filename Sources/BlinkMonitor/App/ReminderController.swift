import SwiftUI
import BlinkCore

/// The reminder settings and the notifications.
///
/// "Are you blinking too little right now?" is NOT stored here: it is computed from the
/// minutes and the threshold each time it is asked (`lowRate`), so it is right the moment
/// either of them changes.
@MainActor
final class ReminderController: ObservableObject {

    /// Under this many blinks a minute is "too little" (see `Settings.threshold`).
    @Published var threshold: Int {
        didSet { settings.threshold = threshold }
    }
    @Published private(set) var remindersOn: Bool
    @Published private(set) var notificationsRefused = false
    @Published private(set) var snoozedUntil: Date?

    private let settings: Settings
    private var policy = ReminderPolicy()
    private let notifier = Notifier()

    init(settings: Settings = Settings()) {
        self.settings = settings
        threshold = settings.threshold
        remindersOn = settings.remindersOn
    }

    /// Your rate over the last 3 minutes while it is under the threshold, else nil.
    func lowRate(in minutes: [MinuteRecord], now: Date = Date()) -> Double? {
        policy.lowRate(records: minutes, threshold: Double(threshold), now: now)
    }

    /// Asks macOS for the right to show notifications, if reminders are wanted.
    func prepare() {
        guard remindersOn else { return }
        notifier.requestPermission { [weak self] granted in
            self?.notificationsRefused = !granted
        }
    }

    func setReminders(_ on: Bool) {
        remindersOn = on
        settings.remindersOn = on
        prepare()
    }

    /// No reminder for this long (nil: reminders are back now).
    func snooze(minutes: Int?, now: Date = Date()) {
        let until = minutes.map { now.addingTimeInterval(Double($0) * 60) }
        policy.snooze(until: until)
        snoozedUntil = until
    }

    /// A minute just ended: show a reminder if one is due.
    func minuteEnded(minutes: [MinuteRecord], now: Date = Date()) {
        if let snoozedUntil, now >= snoozedUntil { self.snoozedUntil = nil }
        guard remindersOn, let low = lowRate(in: minutes, now: now),
              policy.reminderDue(rate: low, threshold: Double(threshold), now: now) else { return }
        notifier.remind(title: "Time to blink",
                        body: String(format: "About %.0f blinks a minute over the last 3 minutes. "
                                     + "Close your eyes gently a few times.", low))
    }
}
