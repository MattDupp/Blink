import Foundation
import AppKit
import UserNotifications

/// Decides when to tell you that you are not blinking enough.
///
/// Two things would make reminders useless: firing on too little evidence (one quiet
/// minute while you think) and firing again and again. So:
///   - the rate is taken over the last 3 minutes, and only if your eyes were really
///     watched for at least 2 of them (no reminder for the time you were away);
///   - after a reminder, none for 5 minutes, however low the rate stays.
struct ReminderPolicy {

    var windowMinutes = 3
    var minimumObservedSeconds = 120.0
    var cooldownSeconds = 300.0
    private(set) var lastReminder: Date?

    /// Blinks per minute over the last minutes, or nil when too little was watched.
    func recentRate(records: [MinuteRecord], now: Date) -> Double? {
        let oldest = MinuteRecord.minuteStart(of: now).addingTimeInterval(-Double(windowMinutes) * 60)
        let recent = records.filter { $0.start >= oldest && $0.start <= now }
        let observed = recent.reduce(0) { $0 + $1.observedSeconds }
        guard observed >= minimumObservedSeconds else { return nil }
        return Double(recent.reduce(0) { $0 + $1.blinks }) / observed * 60
    }

    /// True when a reminder should be shown now; it then starts the 5-minute pause.
    mutating func reminderDue(rate: Double?, threshold: Double, now: Date) -> Bool {
        guard let rate, rate < threshold else { return false }
        if let lastReminder, now.timeIntervalSince(lastReminder) < cooldownSeconds { return false }
        lastReminder = now
        return true
    }
}

/// Shows the reminder as a macOS notification (the banner at the top right).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    /// macOS only gives notifications to a real app (a bundle with an identifier).
    /// Run as a bare program - the self-test - there is none, and asking would crash.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private(set) var allowed = false

    /// Asks macOS for the right to show notifications (macOS asks you once).
    func requestPermission(_ done: @escaping (Bool) -> Void) {
        guard let center else { done(false); return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.allowed = granted
                done(granted)
            }
        }
    }

    func remind(title: String, body: String) {
        guard allowed, let center else {
            // No right to show a banner: a soft sound is better than silence.
            NSSound(named: "Glass")?.play()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // One fixed identifier: a new reminder replaces the previous banner instead of
        // piling up in Notification Centre.
        center.add(UNNotificationRequest(identifier: "low-blink-rate", content: content, trigger: nil))
    }

    // Without this, macOS hides the banner of an app it considers "in front".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
