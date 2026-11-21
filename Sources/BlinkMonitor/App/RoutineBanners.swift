import Foundation
import UserNotifications
import BlinkCore

/// Turns a routine's reminder into a macOS banner with two buttons, Done and Later, and
/// brings the pressed button back to the `RoutineController`.
///
/// It goes through the app's one `Notifier`: macOS allows one delegate and one set of
/// banner kinds per app, so a second, separate object would silently undo the first.
///
/// The banner is SILENT on purpose. A routine is not an alarm: it is shown when you are
/// at the screen, once more ten minutes later, and after that the mark in the menu bar
/// waits without a sound.
@MainActor
final class RoutineBanners {

    private enum Identifier {
        static let category = "routine"
        static let done = "routine-done"
        static let later = "routine-later"
        /// One banner per routine: a new one replaces the previous one.
        static func banner(_ routine: Routine) -> String { "routine-" + routine.id }
    }

    private let notifier: Notifier
    private weak var routines: RoutineController?

    init(notifier: Notifier, routines: RoutineController) {
        self.notifier = notifier
        self.routines = routines
        notifier.extraCategories = [UNNotificationCategory(identifier: Identifier.category, actions: [
            UNNotificationAction(identifier: Identifier.done, title: "Done", options: []),
            UNNotificationAction(identifier: Identifier.later, title: "Later (\(routines.policy.laterMinutes) min)", options: []),
        ], intentIdentifiers: [])]
        notifier.onOtherResponse = { [weak routines] response in
            guard response.category == Identifier.category, let id = response.info["routine"],
                  let slot = response.info["slot"], !slot.isEmpty else { return }      // empty: the test reminder
            switch response.action {
            case Identifier.done: routines?.answer(routine: id, slot: slot, done: true)
            case Identifier.later: routines?.answer(routine: id, slot: slot, done: false)
            default: break      // a click on the banner itself: it stays due, the panel shows it
            }
        }
        routines.onBanner = { [weak self] in self?.show($0) }
        routines.onSettled = { [weak self] in self?.notifier.withdraw(identifier: Identifier.banner($0)) }
    }

    private func show(_ banner: RoutineBanner) {
        // Asking again costs nothing: macOS asks the user once, then only answers.
        notifier.requestPermission { [weak self] granted in
            self?.routines?.bannersRefused = !granted
            guard granted, let self else {
                Log.app.notice("Routine reminder not shown: banners are not allowed")
                return
            }
            Log.app.notice("Routine reminder shown: \(banner.routine.id, privacy: .public), test: \(banner.slot == nil, privacy: .public)")
            self.notifier.show(Self.content(for: banner), identifier: Identifier.banner(banner.routine))
        }
    }

    /// What the banner says. No advice in it: the routine and its times are the user's.
    static func content(for banner: RoutineBanner, later minutes: Int = RoutinePolicy().laterMinutes) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Identifier.category
        content.sound = nil
        content.title = banner.routine.name
        if let slot = banner.slot {
            let time = Format.time(slot.due)
            content.body = banner.kept ? "Your \(time) reminder, kept until you were back."
                                       : "Your \(time) reminder."
            content.userInfo = ["routine": slot.routine, "slot": slot.key]
        } else {
            content.body = "This is a test. A real reminder looks like this, and its buttons mark it done or put it off \(minutes) minutes."
            content.userInfo = ["routine": banner.routine.id, "slot": ""]
        }
        return content
    }
}
