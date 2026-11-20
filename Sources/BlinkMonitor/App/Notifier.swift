import AppKit
import UserNotifications
import BlinkCore

/// Shows the app's nudges as macOS notifications (the banner at the top right), and
/// reports which of a banner's buttons was pressed.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    /// What the app can tell you.
    enum Notice {
        /// You blink too little: `recent` is the rate over the last three minutes.
        case lowRate(recent: Double)
        /// You have been at the screen for this many minutes without a break.
        case screenBreak(minutes: Int)
    }

    /// What a banner's buttons ask for.
    enum Action {
        case blinkBreak
        case snooze
    }

    private enum Identifier {
        static let lowRate = "low-blink-rate"
        static let screenBreak = "screen-break"
        static let blinkBreak = "start-blink-break"
        static let snooze = "snooze-one-hour"
    }

    /// Called on the main thread when a button of a banner is pressed.
    var onAction: (@MainActor (Action) -> Void)?

    /// macOS only gives notifications to a real app (a bundle with an identifier).
    /// Run as a bare program there is none, and asking would crash.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private(set) var allowed = false

    /// Asks macOS for the right to show notifications (macOS asks the user once).
    func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else {
            Task { @MainActor in done(false) }
            return
        }
        center.delegate = self
        // A "category" is a kind of banner with its own buttons.
        let lowRate = UNNotificationCategory(identifier: Identifier.lowRate, actions: [
            // `.foreground`: pressing it brings the app forward, to show the exercise.
            UNNotificationAction(identifier: Identifier.blinkBreak, title: "Start Blink Break", options: [.foreground]),
            UNNotificationAction(identifier: Identifier.snooze, title: "Snooze 1 Hour", options: []),
        ], intentIdentifiers: [])
        center.setNotificationCategories([lowRate])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error { Log.app.error("Notifications: \(error.localizedDescription, privacy: .public)") }
            Task { @MainActor in
                self?.allowed = granted
                done(granted)
            }
        }
    }

    func show(_ notice: Notice) {
        guard allowed, let center else {
            // No right to show a banner: a soft sound is better than silence.
            NSSound(named: "Glass")?.play()
            return
        }
        let content = UNMutableNotificationContent()
        content.sound = .default
        let identifier: String
        switch notice {
        case .lowRate(let recent):
            identifier = Identifier.lowRate
            content.categoryIdentifier = Identifier.lowRate
            content.title = "Time to blink"
            content.body = String(format: "About %.0f blinks a minute over the last 3 minutes. "
                                  + "Ten slow, full blinks help.", recent)
        case .screenBreak(let minutes):
            identifier = Identifier.screenBreak
            content.title = "Look far away for 20 seconds"
            content.body = "You have been at the screen for \(minutes) minutes. Pick something across the room, or out of the window."
        }
        // One fixed identifier per kind: a new banner replaces the previous one instead of
        // piling up in Notification Centre.
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    // Without this, macOS hides the banner of an app it considers "in front".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // A button of a banner, or the banner itself, was pressed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let aboutLowRate = response.notification.request.content.categoryIdentifier == Identifier.lowRate
        let action: Action?
        switch response.actionIdentifier {
        case Identifier.blinkBreak: action = .blinkBreak
        case Identifier.snooze: action = .snooze
        // A click on the "time to blink" banner itself is taken as "yes, let us do it".
        case UNNotificationDefaultActionIdentifier: action = aboutLowRate ? .blinkBreak : nil
        default: action = nil
        }
        if let action {
            Task { @MainActor [weak self] in self?.onAction?(action) }
        }
        completionHandler()
    }
}
