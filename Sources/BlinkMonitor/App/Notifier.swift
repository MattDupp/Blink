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
        /// A look-away break starts (the words come from `BreakWords`). `canPostpone`:
        /// the banner still offers "In 5 Minutes".
        case screenBreak(title: String, body: String, canPostpone: Bool)
    }

    /// What a banner's buttons ask for.
    enum Action {
        case blinkBreak
        case snooze
        case postponeBreak
        case skipBreak
    }

    private enum Identifier {
        static let lowRate = "low-blink-rate"
        static let screenBreak = "screen-break"
        static let blinkBreak = "start-blink-break"
        static let snooze = "snooze-one-hour"
        /// A break that was already put off once: the same banner without that button.
        static let screenBreakLast = "screen-break-last"
        static let postponeBreak = "break-in-five-minutes"
        static let skipBreak = "skip-break"
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
        // Neither button brings the app forward: you are about to look away.
        let later = UNNotificationAction(identifier: Identifier.postponeBreak, title: "In 5 Minutes", options: [])
        let skip = UNNotificationAction(identifier: Identifier.skipBreak, title: "Skip", options: [])
        let screenBreak = UNNotificationCategory(identifier: Identifier.screenBreak, actions: [later, skip], intentIdentifiers: [])
        let screenBreakLast = UNNotificationCategory(identifier: Identifier.screenBreakLast, actions: [skip], intentIdentifiers: [])
        center.setNotificationCategories([lowRate, screenBreak, screenBreakLast])
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
            // No right to show a banner: a soft sound is better than silence. A break has
            // a sound of its own for its start: "Glass" is the one that says it is over.
            if case .screenBreak = notice { NSSound(named: "Ping")?.play() } else { NSSound(named: "Glass")?.play() }
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
        case .screenBreak(let title, let body, let canPostpone):
            identifier = Identifier.screenBreak
            content.categoryIdentifier = canPostpone ? Identifier.screenBreak : Identifier.screenBreakLast
            content.title = title
            content.body = body
        }
        // One fixed identifier per kind: a new banner replaces the previous one instead of
        // piling up in Notification Centre.
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// The break is over: its banner, if it is still on screen or in Notification Centre,
    /// would now ask for something that is done.
    func withdrawScreenBreak() {
        center?.removeDeliveredNotifications(withIdentifiers: [Identifier.screenBreak])
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
        case Identifier.postponeBreak: action = .postponeBreak
        case Identifier.skipBreak: action = .skipBreak
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
