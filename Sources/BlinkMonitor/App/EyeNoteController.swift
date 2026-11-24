import SwiftUI
import UserNotifications
import BlinkCore

/// The optional evening question, "How do your eyes feel?", and the notes it collects.
///
/// Off unless chosen. The answer is one tap, on the banner or in the History window, and
/// it is the person's own note: the app keeps it in `eye-notes.csv` and shows it in a row
/// under the week. It does nothing else with it. It does not compare it with the blink
/// rate, does not comment on it, and does not advise.
///
/// The banner goes through the app's one `Notifier` and the one gate, like every other.
@MainActor
final class EyeNoteController: ObservableObject {

    @Published private(set) var notes: [EyeNote]
    let store: EyeNoteStore

    /// May the banner show now, and it was shown: the gate, through `ReminderController`.
    var mayShowBanner: (Date) -> Bool = { _ in true }
    var bannerShown: (Date) -> Void = { _ in }
    /// The question was asked, by banner (the tests read it).
    var onAsked: () -> Void = {}

    private let preferences: Preferences
    private weak var notifier: Notifier?

    private enum Identifier {
        static let category = "eye-note"
        static let banner = "eye-note"
        static func action(_ feeling: EyeFeeling) -> String { "eye-note-" + feeling.rawValue }
    }

    init(preferences: Preferences, store: EyeNoteStore = EyeNoteStore(file: EyeNoteStore.defaultFile)) {
        self.preferences = preferences
        self.store = store
        notes = store.load()
    }

    /// Notes of their own in the temporary folder, emptied at each start: the demo, the
    /// screenshots and the tests never write to the user's real file.
    static func scratch(preferences: Preferences) -> EyeNoteController {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-sample-eye-notes.csv")
        try? FileManager.default.removeItem(at: file)
        return EyeNoteController(preferences: preferences, store: EyeNoteStore(file: file))
    }

    /// Registers the banner's four buttons with the app's one `Notifier`.
    func connect(to notifier: Notifier) {
        self.notifier = notifier
        notifier.extraCategories.append(UNNotificationCategory(
            identifier: Identifier.category,
            actions: EyeFeeling.allCases.map { UNNotificationAction(identifier: Identifier.action($0), title: EyeNoteWords.name($0), options: []) },
            intentIdentifiers: []))
        notifier.responders.append { [weak self] response in
            guard response.category == Identifier.category,
                  let feeling = EyeFeeling.allCases.first(where: { Identifier.action($0) == response.action }) else { return }
            self?.note(feeling)
        }
    }

    /// Today's note, if any.
    func today(now: Date = Date(), calendar: Calendar = .current) -> EyeFeeling? {
        EyeNotes.byDay(notes)[SummarySchedule.key(of: now, calendar: calendar)]
    }

    /// The answer: written down for today. A second answer the same day replaces the first.
    func note(_ feeling: EyeFeeling, now: Date = Date(), calendar: Calendar = .current) {
        let note = EyeNote(feeling: feeling, at: now, calendar: calendar)
        notes.append(note)
        store.append(note)
        notifier?.withdraw(identifier: Identifier.banner)
    }

    /// Erases every note, on disk and in memory.
    func erase() {
        if store.erase() { notes = [] }
    }

    /// States the notes, for the screenshots and the demo.
    func state(notes: [EyeNote]) {
        self.notes = notes
    }

    /// A minute of counting ended: ask, if the question is on, its hour has come, it was
    /// not asked today, today has no note yet, and the gate lets a banner through.
    func askIfDue(now: Date = Date(), calendar: Calendar = .current) {
        guard preferences.eyeNoteOn,
              SummarySchedule.isDue(now: now, hour: preferences.eyeNoteHour, lastShown: preferences.eyeNoteAskedDay, calendar: calendar)
        else { return }
        // Already answered in History: there is nothing to ask.
        guard today(now: now, calendar: calendar) == nil else {
            preferences.eyeNoteAskedDay = SummarySchedule.key(of: now, calendar: calendar)
            return
        }
        guard mayShowBanner(now) else { return }
        preferences.eyeNoteAskedDay = SummarySchedule.key(of: now, calendar: calendar)
        bannerShown(now)
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Identifier.category
        content.title = EyeNoteWords.question
        content.body = EyeNoteWords.bannerBody
        content.sound = nil
        notifier?.show(content, identifier: Identifier.banner)
        onAsked()
        Log.app.notice("Evening question asked")
    }
}

/// The words of the evening question. Four plain words for a feeling, and nothing that
/// reads as a finding: no "better", no "worse", no "because".
enum EyeNoteWords {
    static let question = "How do your eyes feel?"
    static let bannerBody = "One tap, from the buttons of this banner. It is your own note: Blink keeps it on this Mac and shows it in History."

    static func name(_ feeling: EyeFeeling) -> String {
        switch feeling {
        case .fine: return "Fine"
        case .aLittleTired: return "A little tired"
        case .tired: return "Tired"
        case .veryTired: return "Very tired"
        }
    }

    /// The row in History.
    static let rowTitle = "How your eyes felt, as you noted it"
    static let todayMenu = "Today…"
    static func spoken(_ feeling: EyeFeeling?) -> String { feeling.map(name) ?? "no note" }

    /// The rows in Settings.
    static let row = "An evening question"
    static let detail = "Once a day, a silent banner asks how your eyes feel: one tap on Fine, A little tired, Tired or Very tired. It is your own note. Blink keeps it on this Mac, shows it under the week in History, and does nothing else with it."
    static let hourRow = "Hour of the question"
    static let hourDetail = "The banner comes at the first minute counted from this hour on. You can also note it in History, where it can be changed."

    /// The row in the Privacy tab.
    static let fileTitle = "Eye notes"
    static let fileDetail = "Your answers to the evening question, one line each."
}
