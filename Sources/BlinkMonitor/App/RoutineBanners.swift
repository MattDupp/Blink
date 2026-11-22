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
        /// A routine with a timer: the same banner, with one more button.
        static let timedCategory = "routine-timed"
        static let start = "routine-start"
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
        let done = UNNotificationAction(identifier: Identifier.done, title: "Done", options: [])
        let later = UNNotificationAction(identifier: Identifier.later, title: "Later (\(routines.policy.laterMinutes) min)", options: [])
        // `.foreground`: pressing it brings the app forward, to show the timer's window.
        let start = UNNotificationAction(identifier: Identifier.start, title: "Start Timer", options: [.foreground])
        notifier.extraCategories = [
            UNNotificationCategory(identifier: Identifier.category, actions: [done, later], intentIdentifiers: []),
            UNNotificationCategory(identifier: Identifier.timedCategory, actions: [start, later, done], intentIdentifiers: []),
        ]
        notifier.onOtherResponse = { [weak routines] response in
            guard [Identifier.category, Identifier.timedCategory].contains(response.category),
                  let id = response.info["routine"],
                  let slot = response.info["slot"], !slot.isEmpty else { return }      // empty: the test reminder
            switch response.action {
            case Identifier.start: routines?.startSession(id)
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
        content.categoryIdentifier = banner.routine.sessionMinutes == nil ? Identifier.category : Identifier.timedCategory
        content.sound = nil
        // `title`, not `name`: the name is typed by the user, and is cleaned once more here.
        content.title = banner.routine.title
        if let slot = banner.slot {
            let time = Format.time(slot.due)
            if let minutes = banner.routine.screenMinutes {
                // "At the screen": it has no time of its own to name.
                content.body = "\(minutes) minutes at the screen."
            } else {
                content.body = banner.kept ? "Your \(time) reminder, kept until you were back."
                                           : "Your \(time) reminder."
            }
            if let week = banner.week { content.body += " \(week.done) of \(week.target) done this week." }
            content.userInfo = ["routine": slot.routine, "slot": slot.key]
        } else {
            content.body = "This is a test. A real reminder looks like this, and its buttons mark it done or put it off \(minutes) minutes."
            content.userInfo = ["routine": banner.routine.id, "slot": ""]
        }
        return content
    }
}
