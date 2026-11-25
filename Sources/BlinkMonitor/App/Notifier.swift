import AppKit
import UserNotifications
import BlinkCore

/// Shows the app's nudges as macOS notifications (the banner at the top right), and
/// reports which of a banner's buttons was pressed.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    /// What the app can tell you.
    enum Notice {
        /// You blink too little: `recent` is the rate over the last three minutes.
        /// `sound`: false once the reminder has gone unanswered twice (`ReminderPolicy`).
        case lowRate(limit: Int, sound: Bool)
        /// "Send a Test Reminder": the same banner, said to be a test, whose buttons do nothing.
        case lowRateTest
        /// A look-away break starts (the words come from `BreakWords`). `canPostpone`:
        /// the banner still offers "Later (5 min)".
        /// `sound`: the banner comes with the Mac's notification sound (a setting).
        case screenBreak(title: String, body: String, canPostpone: Bool, sound: Bool)
        /// "Send a Test Reminder" in Settings > Breaks: the break's banner with its real
        /// numbers, said to be a test, whose buttons do nothing.
        case screenBreakTest(title: String, body: String)
    }

    /// What a banner's buttons ask for.
    enum Action {
        case blinkBreak
        case snooze
        case postponeBreak
        case skipBreak
        /// A click on a banner itself, of any kind: the panel opens. It holds the right
        /// buttons for whatever the banner was about.
        case openPanel
    }

    private enum Identifier {
        static let lowRate = "low-blink-rate"
        static let lowRateTest = "low-blink-rate-test"
        static let screenBreak = "screen-break"
        static let screenBreakTest = "screen-break-test"
        static let breakOver = "screen-break-over"
        static let blinkBreak = "start-blink-break"
        static let snooze = "snooze-one-hour"
        /// A break that was already put off once: the same banner without that button.
        static let screenBreakLast = "screen-break-last"
        static let postponeBreak = "break-in-five-minutes"
        static let skipBreak = "skip-break"
    }

    /// Called on the main thread when a button of one of the notifier's own banners is pressed.
    var onAction: (@MainActor (Action) -> Void)?

    /// A press on a banner of another kind (the routines, the evening question).
    struct OtherResponse {
        let category: String
        let action: String
        let info: [String: String]
    }

    /// The other kinds of banner, with their buttons. macOS keeps ONE set of kinds per
    /// app: they are all given together, each time one is added.
    private var otherCategories: [UNNotificationCategory] = []
    /// Each other kind's answer: handed every press that is not the notifier's own, it
    /// takes its own. Kinds are only ever added (the routines used to hold a slot of
    /// their own, which a second kind could have taken from them).
    private var responders: [@MainActor (OtherResponse) -> Void] = []
    /// The kinds have been given to macOS once: a kind added later is given at once.
    private var categoriesGiven = false

    /// Adds a kind of banner: its buttons, and what a press on one of them does.
    func register(_ categories: [UNNotificationCategory], respond: @escaping @MainActor (OtherResponse) -> Void) {
        otherCategories += categories
        responders.append(respond)
        if categoriesGiven { giveCategories() }
    }

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
            UNNotificationAction(identifier: Identifier.snooze, title: "Quiet for 1 Hour", options: []),
        ], intentIdentifiers: [])
        // Neither button brings the app forward: you are about to look away.
        let later = UNNotificationAction(identifier: Identifier.postponeBreak, title: "Later (5 min)", options: [])
        let skip = UNNotificationAction(identifier: Identifier.skipBreak, title: "Skip", options: [])
        let screenBreak = UNNotificationCategory(identifier: Identifier.screenBreak, actions: [later, skip], intentIdentifiers: [])
        let screenBreakLast = UNNotificationCategory(identifier: Identifier.screenBreakLast, actions: [skip], intentIdentifiers: [])
        // The test banner looks the same, and its buttons carry identifiers nothing acts
        // on: a test must not start a snooze of an hour.
        let lowRateTest = UNNotificationCategory(identifier: Identifier.lowRateTest, actions: [
            UNNotificationAction(identifier: "test-blink-break", title: "Start Blink Break", options: []),
            UNNotificationAction(identifier: "test-snooze", title: "Quiet for 1 Hour", options: []),
        ], intentIdentifiers: [])
        let screenBreakTest = UNNotificationCategory(identifier: Identifier.screenBreakTest, actions: [
            UNNotificationAction(identifier: "test-later", title: "Later (5 min)", options: []),
            UNNotificationAction(identifier: "test-skip", title: "Skip", options: []),
        ], intentIdentifiers: [])
        ownCategories = [lowRate, lowRateTest, screenBreak, screenBreakLast, screenBreakTest]
        giveCategories()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error { Log.app.error("Notifications: \(error.localizedDescription, privacy: .public)") }
            Task { @MainActor in
                self?.allowed = granted
                done(granted)
            }
        }
    }

    private var ownCategories: [UNNotificationCategory] = []

    private func giveCategories() {
        center?.setNotificationCategories(Set(ownCategories + otherCategories))
        categoriesGiven = true
    }

    /// What macOS says now, without asking: true, false, or nil when the question was
    /// never answered (or there is no app to ask for).
    func readPermission(_ done: @escaping @MainActor (Bool?) -> Void) {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let answer: Bool?
            switch settings.authorizationStatus {
            case .authorized, .provisional: answer = true
            case .denied: answer = false
            default: answer = nil
            }
            Task { @MainActor in
                if let answer { self?.allowed = answer }
                done(answer)
            }
        }
    }

    func show(_ notice: Notice) {
        guard allowed, let center else {
            // No right to show a banner: a soft sound is better than silence. A break has
            // a sound of its own for its start: "Glass" is the one that says it is over.
            // ONE MEANING PER SOUND. "Ping": a break starts. "Glass" means "over, you may
            // come back", and nothing else: the blink reminder used to borrow it here. It
            // now stays silent without banners: the menu bar's orange number says it.
            if case .screenBreak(_, _, _, let sound) = notice, sound { NSSound(named: "Ping")?.play() }
            return
        }
        let content = UNMutableNotificationContent()
        content.sound = .default
        let identifier: String
        switch notice {
        case .lowRate(let limit, let sound):
            identifier = Identifier.lowRate
            content.categoryIdentifier = Identifier.lowRate
            content.title = "Time to blink"
            content.body = LowRateWords.sentence(limit: limit) + " Try \(ReminderWords.exercise)."
            if !sound { content.sound = nil }
        case .lowRateTest:
            identifier = Identifier.lowRateTest
            content.categoryIdentifier = Identifier.lowRateTest
            content.title = "Time to blink (this is a test)"
            content.body = "This is how a reminder looks. Move the pointer over it to see its buttons. On this test they do nothing."
        case .screenBreak(let title, let body, let canPostpone, let sound):
            identifier = Identifier.screenBreak
            content.categoryIdentifier = canPostpone ? Identifier.screenBreak : Identifier.screenBreakLast
            content.title = title
            content.body = body
            if !sound { content.sound = nil }
            center.removeDeliveredNotifications(withIdentifiers: [Identifier.breakOver])
        case .screenBreakTest(let title, let body):
            identifier = Identifier.screenBreakTest
            content.categoryIdentifier = Identifier.screenBreakTest
            content.title = title + " (this is a test)"
            content.body = body + " On this test the buttons do nothing."
        }
        // One fixed identifier per kind: a new banner replaces the previous one instead of
        // piling up in Notification Centre.
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// A look-away break is over: the sound that says so.
    ///
    /// It goes THROUGH THE NOTIFICATION SYSTEM when the app may use it: the sound is then
    /// the Mac's own notification sound, at its volume, and it keeps quiet under a Focus
    /// and when notification sounds are switched off for the app. (The first version
    /// played a sound file directly, every 20 minutes, whatever the Mac was set to.) The
    /// short banner that carries it also says "over" to a muted Mac; it is taken back
    /// after a few seconds. Without the right to notify, the sound file is all there is.
    /// `sound` false (switched off in Settings): the banner alone, which is also what a
    /// muted Mac gets. A break must not end unseen AND unheard.
    func breakOver(sound: Bool = true) {
        guard allowed, let center else {
            if sound { NSSound(named: "Glass")?.play() }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Break over"
        content.body = "You can look back at the screen."
        content.sound = sound ? .default : nil
        center.add(UNNotificationRequest(identifier: Identifier.breakOver, content: content, trigger: nil))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            center.removeDeliveredNotifications(withIdentifiers: [Identifier.breakOver])
        }
    }

    /// A silent line about a break ("Long break done", "4 of 5 minutes away"), taken back
    /// after a while. Nothing without the right to notify: the panel says the same.
    func breakNote(title: String, body: String) {
        guard allowed, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        center.add(UNNotificationRequest(identifier: Identifier.breakOver, content: content, trigger: nil))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            center.removeDeliveredNotifications(withIdentifiers: [Identifier.breakOver])
        }
    }

    /// The blink reminder was answered (a blink break was done): its banner would now ask
    /// for something that is done.
    func withdrawLowRate() {
        center?.removeDeliveredNotifications(withIdentifiers: [Identifier.lowRate])
    }

    /// The break is over: its banner, if it is still on screen or in Notification Centre,
    /// would now ask for something that is done.
    func withdrawScreenBreak() {
        center?.removeDeliveredNotifications(withIdentifiers: [Identifier.screenBreak])
    }

    /// Shows a banner of another kind, as it is given. Nothing is shown, and no sound is
    /// played, when banners are not allowed: what it says must also be on screen elsewhere.
    func show(_ content: UNNotificationContent, identifier: String) {
        guard allowed, let center else { return }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Takes a banner back, from the screen and from Notification Centre.
    func withdraw(identifier: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    // Without this, macOS hides the banner of an app it considers "in front".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // `.sound` allows a sound; a banner that carries none (a routine's) stays silent.
        completionHandler([.banner, .sound])
    }

    // A button of a banner, or the banner itself, was pressed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // The test banner: nothing it carries does anything.
        let kind = response.notification.request.content.categoryIdentifier
        if kind == Identifier.lowRateTest || kind == Identifier.screenBreakTest { return completionHandler() }
        let action: Action?
        switch response.actionIdentifier {
        case Identifier.blinkBreak: action = .blinkBreak
        case Identifier.snooze: action = .snooze
        case Identifier.postponeBreak: action = .postponeBreak
        case Identifier.skipBreak: action = .skipBreak
        // A click on a banner itself opens the panel, whatever the banner. On the blink
        // banner it used to start the exercise, sounds included, and on the others it did
        // nothing one could see; many people click a banner only to make it go.
        case UNNotificationDefaultActionIdentifier: action = .openPanel
        default: action = nil
        }
        if let action {
            Task { @MainActor [weak self] in self?.onAction?(action) }
        } else {
            let content = response.notification.request.content
            let other = OtherResponse(category: content.categoryIdentifier, action: response.actionIdentifier,
                                      info: content.userInfo as? [String: String] ?? [:])
            Task { @MainActor [weak self] in self?.responders.forEach { $0(other) } }
        }
        completionHandler()
    }
}
