import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

/// What the Settings window's buttons do outside of it.
struct SettingsActions {
    var startBlinkBreak: () -> Void = {}
    var openLiveView: () -> Void = {}
    /// Opens the setup window: to go on, to add a session, or to take the test again.
    var openSetup: (SetupModel.Purpose) -> Void = { _ in }
    /// Closes the setup window: what it shows is about to be deleted.
    var closeSetup: () -> Void = {}
    /// System Settings, on the page of this app's notifications.
    var openNotificationSettings: () -> Void = {}
    /// System Settings, on the page of the login items.
    var openLoginItems: () -> Void = {}
    /// Removes everything the app keeps on this Mac, then quits. Nil where it is not
    /// offered (the demo, which keeps nothing).
    var deleteEverythingAndQuit: (() -> Void)?
}

/// The questions people ask after a few days, answered where they look for the version.
/// Each answer says what the app does, checked against its code, and nothing about health.
enum GoodToKnow {
    static let all: [(question: String, answer: String)] = [
        ("Does it count someone else's blinks?",
         "It reads one face: the largest in view, which is the one at the keyboard. Someone behind you is not counted. Someone who sits in your place is: the app does not know whose eyes they are."),
        ("Does it work during a video call?",
         "Yes. macOS lets several apps use the camera together, and the call does not see what Blink does. For no reminders meanwhile, use Quiet in the panel, or Quiet during calls in General."),
        ("New glasses, a new desk, a new camera?",
         "Your model learned your eyes as they looked when you recorded them. After a change, test it under Model. If it counts fewer than 8 of 10, add a recording there."),
        ("Why is my rate lower than what I read elsewhere?",
         "The app counts complete blinks only, and people blink less at a screen than in conversation. What it compares with is your own usual rate."),
        ("Can I leave it running all day?",
         "Yes: that is what it is for. Pause turns the camera off whenever you want, and it rests by itself when the screen sleeps."),
    ]
}

/// "Send a Test Reminder", by what macOS allows. A test with notifications off did
/// nothing at all, and the first one made macOS ask its question with no warning.
enum TestReminderWords {
    static let send = "Send a Test Reminder"
    static let openSettings = "Open Notification Settings"
    static let refused = "Notifications are off for Blink, so a test has nothing to show. "
        + "Allow them in System Settings > Notifications > Blink, then send the test."
    static let asksFirst = "macOS first asks whether Blink may show notifications: choose Allow."

    /// The sentence beside the button. `usual`: what the test shows when it can.
    static func detail(_ usual: String, notifications: ReminderController.Notifications) -> String {
        switch notifications {
        case .allowed: return usual
        case .unknown: return usual + " " + asksFirst
        case .refused: return refused
        }
    }
}

/// The button of a test reminder. With notifications refused it cannot show anything,
/// so it becomes the way to allow them.
struct TestReminderButton: View {
    let notifications: ReminderController.Notifications
    let openSettings: () -> Void
    let send: () -> Void

    var body: some View {
        if notifications == .refused {
            Button(TestReminderWords.openSettings, action: openSettings)
        } else {
            Button(TestReminderWords.send, action: send)
        }
    }
}

/// What the app says about the choice of a camera (`CameraChoice`).
enum CameraWords {
    static func detail(inUse name: String?, macHasLid: Bool = true) -> String {
        "Automatic uses the Mac's own camera, and another one when that sends no picture for "
            + "\(Int(CameraChoice.silenceBeforeFallback)) seconds\(macHasLid ? ", as with the lid closed" : ""). "
            + "Your model learned your eyes on one camera: after changing, test it again under Model."
            + (name.map { " In use: \($0)." } ?? "")
    }

    /// In the panel, after Automatic moved to another camera.
    static func moved(to name: String) -> String {
        "The Mac's own camera sent no picture, so Blink is using “\(name)”. "
            + "Your model learned your eyes on another camera: test it again in Settings > Model."
    }
}

/// The project's pages. The app itself connects to nothing: these open in the browser.
enum ProjectLinks {
    static let home = URL(string: "https://github.com/MattDupp/Blink")!
    static let problems = URL(string: "https://github.com/MattDupp/Blink/issues")!
    static let newVersion = URL(string: "https://github.com/MattDupp/Blink/releases/latest")!
}

/// What each erasing action of Settings asks before it acts (`Confirm`): what goes, in
/// the user's words, and that it cannot be undone.
enum EraseWords {
    static func history(startingLimit: Int) -> Confirm.Question {
        Confirm.Question(title: "Erase the history?",
                         text: "Every recorded minute is erased, and your usual rate measured from them. "
                             + "The limit goes back to \(startingLimit) until it is measured again. This cannot be undone.",
                         button: "Erase")
    }

    static let routineLog = Confirm.Question(
        title: "Erase the routine log?",
        text: "What you did with your routines is erased: today's and this week's marks start again. "
            + "The routines and their times stay. This cannot be undone.",
        button: "Erase")

    static let breakLog = Confirm.Question(
        title: "Erase the break log?",
        text: "The breaks you took or skipped, the blink breaks you finished and the blink reminders shown are erased: "
            + "History no longer counts them. Your history of blinks stays. This cannot be undone.",
        button: "Erase")

    static let eyeNotes = Confirm.Question(
        title: "Erase your eye notes?",
        text: "Every answer you gave to the evening question is erased, and its row in History is empty again. This cannot be undone.",
        button: "Erase")

    static func captures(_ count: Int) -> Confirm.Question {
        Confirm.Question(title: "Erase the captures from Live View?",
                         text: "\(Format.count(count, "capture")) of your eyes, saved with Live View's record buttons. This cannot be undone.",
                         button: "Erase")
    }

    static func recordingsAndModel(_ what: String) -> Confirm.Question {
        Confirm.Question(title: "Delete the recordings and the model?", text: what, button: "Delete")
    }

    /// Not an erasure of anything recorded, but it cannot be undone either: same question.
    static let choices = Confirm.Question(
        title: "Reset every setting to its default?",
        text: "The switches and numbers of General, Blink Rate and Breaks go back to how they were on the first day, and the camera to Automatic. "
            + "Your usual rate, your history, your model, your routines and Start at login stay as they are. This cannot be undone.",
        button: "Reset")

    static let startAgain = Confirm.Question(
        title: "Start again?",
        text: "The recordings and the model are deleted, then setup opens to record your eyes anew. "
            + "Nothing is counted until it is done. This cannot be undone.",
        button: "Delete and Start Again")

    static let everything = Confirm.Question(
        title: "Delete everything and quit?",
        text: "The recordings of your eyes, your model, the history, the routine log, the break log, your eye notes and every setting are removed from this Mac, "
            + "and Blink quits. Afterwards, move Blink itself to the Trash. This cannot be undone.",
        button: "Delete Everything and Quit")
}

/// Where the files that setup makes are kept.
struct SettingsFiles {
    var store: ModelStore
    var sessionsRoot: URL
    /// False when the sessions folder was named at launch: a developer's data, which
    /// Settings does not delete.
    var ownSessions = true
    /// The app's own captures folder (what Live View's record buttons saved). Nil in the
    /// demo. A folder named at launch (`--capture-dir`) is a developer's and is not this.
    var capturesRoot: URL?
}

/// What the Settings window remembers while it is open.
@MainActor
final class SettingsState: ObservableObject {

    enum Tab: String, CaseIterable {
        case general = "General"
        case reminders = "Blink Rate"
        case breaks = "Breaks"
        case routines = "Routines"
        case model = "Model"
        case data = "Privacy"
        /// The version, the links and the studies. (It was "Sources": the name of the case
        /// and of its screenshots stayed.)
        case sources = "About"
    }

    /// What setup has left on disk: counted when the window opens, not at every redraw.
    struct OnDisk: Equatable {
        var sessions = 0
        var pictures = 0
        var megabytes = 0.0
        /// Captures in the app's own folder (saved from Live View), and their size.
        var captures = 0
        var captureMegabytes = 0.0
        /// A model trained here that has not passed (or been excused from) its test.
        var untested = false
    }

    /// The outcome of "Measure Again", waiting for your decision.
    enum Measurement: Equatable {
        case proposed(Baseline.Proposal)
        case tooLittle
    }

    @Published var tab = Tab.general
    @Published var measurement: Measurement?
    @Published var onDisk = OnDisk()
    /// The cameras this Mac offers: asked when the window opens.
    @Published var cameras: [CameraOption] = []
    /// Set by the screenshots, which state what is on disk instead of counting it.
    var onDiskIsStated = false
    @Published var deleteProblem: String?

    func reset() {
        measurement = nil
        deleteProblem = nil
    }

    /// Counts what is on disk again.
    func refresh(_ files: SettingsFiles) {
        guard !onDiskIsStated else { return }
        cameras = CameraCapture.options()
        let sessions = SessionStore.sessions(in: files.sessionsRoot)
        let bytes = SessionStore.bytes(under: files.sessionsRoot) + SessionStore.bytes(under: files.store.folder)
        let captures = files.capturesRoot.map { root in
            ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter(\.hasDirectoryPath)
        } ?? []
        let captureBytes = files.capturesRoot.map { captures.isEmpty ? 0 : SessionStore.bytes(under: $0) } ?? 0
        onDisk = OnDisk(sessions: sessions.count, pictures: sessions.reduce(0) { $0 + $1.pictures },
                        megabytes: Double(bytes) / 1_000_000,
                        captures: captures.count, captureMegabytes: Double(captureBytes) / 1_000_000,
                        untested: files.store.info().map { !$0.isAccepted } ?? false)
    }
}

/// The Settings window: every choice the app remembers, with what each one means.
///
/// The first version had its settings in the menu-bar panel, between today's numbers and
/// the buttons. They are set once and looked at rarely; the panel is looked at all day.
struct SettingsView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var history: HistoryController
    @ObservedObject var reminders: ReminderController
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var shortcut: ShortcutController
    @ObservedObject var state: SettingsState
    /// The moment the window describes: the present, except in the screenshots.
    var moment = Moment()
    let files: SettingsFiles
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Section", selection: $state.tab) {
                ForEach(SettingsState.Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)

            // The tab bar stays put, and every tab has the same height: what is taller
            // scrolls under the bar. 110: the title bar, the tab bar and their paddings.
            ScrollsWhenTall(reserved: 110, height: Self.tabHeight) {
                VStack(alignment: .leading, spacing: 12) {
                    if remindsOnThisTab, reminders.notificationsRefused { notificationsOff }
                    switch state.tab {
                    case .general: general
                    case .reminders: remindersTab
                    case .breaks: BreaksTab(model: model, preferences: preferences, reminders: reminders, moment: moment,
                                            openNotificationSettings: actions.openNotificationSettings)
                    case .routines:
                        VStack(alignment: .leading, spacing: 12) {
                            RoutineSettings(routines: model.routines, moment: moment, notifications: reminders.notifications,
                                            openNotificationSettings: actions.openNotificationSettings)
                            eveningQuestionCard
                        }
                    case .model: modelTab
                    case .data: data
                    case .sources: sources
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .padding(.top, 20)
        .windowWidth(520, alignment: .top)
    }

    /// One height for every tab.
    static let tabHeight: CGFloat = 560

    /// The three tabs whose reminders arrive as notifications.
    private var remindsOnThisTab: Bool {
        state.tab == .reminders || state.tab == .breaks || state.tab == .routines
    }

    /// Said at the top of each of those tabs, with the way out. It was said on one tab
    /// only, at the bottom, and only when a switch of that tab was on.
    private var notificationsOff: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.slash")
                .foregroundStyle(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications are off for Blink")
                    .fontWeight(.semibold)
                Text("Reminders cannot show their banner or their buttons. A look-away break then starts and ends with a sound only; the blink reminder and routines only show in the menu bar and the panel. Allow them in System Settings > Notifications > Blink. There, the style Alerts keeps a banner on screen until you answer it.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Notification Settings") { actions.openNotificationSettings() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            generalCard
            workingHoursCard
            if !model.isDemo { energyCard }
            HStack(spacing: 12) {
                Button("Reset to Defaults…") {
                    if Confirm.destructive(EraseWords.choices) { model.resetChoices() }
                }
                .disabled(!preferences.hasChoices)
                .help(preferences.hasChoices ? "" : "Every setting is at its default.")
                Text("Every switch and number in Settings. It keeps your usual rate, your history, your model and your routines.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What counting costs, how much of it to spend (`Effort`), and the two ways to spare
    /// a battery. Also quiet during calls: the other thing the Mac's own state can decide.
    private var energyCard: some View {
        Card {
            Row("Energy", detail: "While it reads your eyes, Blink keeps the camera on and part of one processor core at work. Pause, in the panel, stops both.") {
                EmptyView()
            }
            Divider()
            Row(EffortWords.row, detail: EffortWords.detail(preferences.effort) + " " + EffortWords.whileResting) {
                Picker(EffortWords.row, selection: $preferences.effort) {
                    ForEach(Effort.allCases, id: \.self) { Text(EffortWords.name($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            Row("Rest on battery", detail: "The camera goes off while the Mac runs on its battery, and comes back when it is plugged in. Resume, in the panel, counts anyway.") {
                Toggle("Rest on battery", isOn: $preferences.pauseOnBattery)
            }
            Divider()
            Row("Rest in Low Power Mode", detail: "The same, while Low Power Mode is on in System Settings > Battery.") {
                Toggle("Rest in Low Power Mode", isOn: $preferences.pauseInLowPower)
            }
            Divider()
            Row("Quiet during calls", detail: "No reminder, no look-away break and no sound while an app uses the microphone. Blink only asks macOS whether it is in use: it never listens.") {
                Toggle("Quiet during calls", isOn: $preferences.quietDuringCalls)
            }
        }
    }

    /// The evening question: a reminder on a schedule that the person chose, so it lives
    /// with the routines.
    private var eveningQuestionCard: some View {
        Card {
            Row(EyeNoteWords.row, detail: EyeNoteWords.detail) {
                Toggle(EyeNoteWords.row, isOn: $preferences.eyeNoteOn)
            }
            if preferences.eyeNoteOn {
                Divider()
                let held = SummaryWords.isHeldBack(hour: preferences.eyeNoteHour, by: preferences.workingHours)
                Row(EyeNoteWords.hourRow, detail: held ? SummaryWords.heldBack(hour: preferences.eyeNoteHour) : EyeNoteWords.hourDetail) {
                    Picker(EyeNoteWords.hourRow, selection: $preferences.eyeNoteHour) {
                        ForEach(0..<24, id: \.self) { Text(Format.hour($0)).tag($0) }
                    }
                    .fixedSize()
                }
            }
        }
    }

    /// "Quiet outside working hours": the two times and the days show only while it is on.
    private var workingHoursCard: some View {
        Card {
            Row(QuietWords.title, detail: QuietWords.detail) {
                Toggle(QuietWords.title, isOn: $preferences.workingHoursOn)
            }
            if preferences.workingHoursOn {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Working hours")
                        Spacer(minLength: 12)
                        Text("from")
                            .foregroundStyle(.secondary)
                        timePicker("Start of the working hours", $preferences.workStart)
                        Text("to")
                            .foregroundStyle(.secondary)
                        timePicker("End of the working hours", $preferences.workEnd)
                    }
                    DayChips(calendar: .current, chosen: preferences.workDays,
                             lastDay: "The last day stays: working hours keep at least one") { weekday, on in
                        // The last day stays: with none, the app would be quiet for ever.
                        if on { preferences.workDays.insert(weekday) } else if preferences.workDays.count > 1 { preferences.workDays.remove(weekday) }
                    }
                    if preferences.workStart >= preferences.workEnd {
                        Text(QuietWords.overnight)
                            .textStyle(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    /// A date picker edits a date: the time is placed on today, and read back from it.
    private func timePicker(_ label: String, _ time: Binding<TimeOfDay>) -> some View {
        let calendar = Calendar.current
        return DatePicker(label, selection: Binding(
            get: {
                calendar.date(bySettingHour: time.wrappedValue.hour, minute: time.wrappedValue.minute, second: 0,
                              of: calendar.startOfDay(for: moment.now)) ?? moment.now
            },
            set: { time.wrappedValue = TimeOfDay(hour: calendar.component(.hour, from: $0), minute: calendar.component(.minute, from: $0)) }),
                          displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
    }

    private var generalCard: some View {
        Card {
            Row("Start at login", detail: loginItem.unavailable ?? loginItem.problem
                    ?? "Blink opens by itself when you log in.") {
                // macOS refused: the list it keeps is where that can be mended.
                if loginItem.problem != nil {
                    Button("Open Login Items") { actions.openLoginItems() }
                }
                Toggle("Start at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                    .disabled(!loginItem.available)
            }
            Divider()
            Row("Show the rate in the menu bar", detail: "Off: only the eye is shown, and it changes when your rate is low.") {
                Toggle("Show the rate in the menu bar", isOn: $preferences.showRateInMenuBar)
            }
            Divider()
            Row("Orange when the rate is low", detail: "The number in the menu bar turns orange while your rate is under your limit.") {
                Toggle("Orange when the rate is low", isOn: $preferences.orangeRateWhenLow)
                    .disabled(!preferences.showRateInMenuBar)
                    .help(preferences.showRateInMenuBar ? "" : "The rate is not shown in the menu bar.")
            }
            Divider()
            Row("The menu-bar eye blinks with you", detail: "It closes for a moment at each blink the camera counts.") {
                Toggle("The menu-bar eye blinks with you", isOn: $preferences.blinkBack)
            }
            Divider()
            Row("Larger text", detail: "Sentences, labels and buttons are drawn about 20% larger in every window. The big numbers and the charts keep their size.") {
                Toggle("Larger text", isOn: $preferences.largerText)
            }
            Divider()
            Row(ShortcutWords.title, detail: ShortcutWords.detail(chosen: preferences.blinkBreakShortcut, refused: shortcut.refused)) {
                // "" stands for Off: a picker's tag cannot be nil.
                Picker(ShortcutWords.title, selection: Binding(get: { preferences.blinkBreakShortcut?.rawValue ?? "" },
                                                              set: { preferences.blinkBreakShortcut = ShortcutChoice(rawValue: $0) })) {
                    Text(ShortcutWords.off).tag("")
                    Divider()
                    ForEach(ShortcutChoice.allCases) { Text($0.symbols).accessibilityLabel($0.spoken).tag($0.rawValue) }
                }
                .fixedSize()
            }
            Divider()
            Row("Live View", detail: "The camera with your eyes framed, and each blink as it is counted.") {
                Button("Open Live View") { actions.openLiveView() }
            }
            if !model.isDemo {
                Divider()
                Row("Camera", detail: CameraWords.detail(inUse: model.cameraName, macHasLid: model.macHasLid())) {
                    if state.cameras.count > 1 {
                        // "" stands for Automatic: a picker's tag cannot be nil.
                        Picker("Camera", selection: Binding(get: { preferences.cameraID ?? "" },
                                                            set: { model.setCamera($0.isEmpty ? nil : $0) })) {
                            Text("Automatic").tag("")
                            Divider()
                            ForEach(state.cameras) { Text($0.name).tag($0.id) }
                        }
                        .fixedSize()
                    } else {
                        Text(state.cameras.first?.name ?? model.cameraName ?? "None found")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Reminders

    private var remindersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Row("Remind me when I blink too little",
                    detail: "When your rate stays under the limit for 3 minutes. Left unanswered it backs off: the next after 5, 15, 30, then 60 minutes, with a sound for the first two only. A blink break answers it.") {
                    Toggle("Remind me when I blink too little", isOn: $preferences.remindersOn)
                }
                Divider()
                Row("See what it looks like",
                    detail: TestReminderWords.detail("Shows a reminder now, marked as a test. Its two buttons show when the pointer is over it, and on the test they do nothing.",
                                                     notifications: reminders.notifications)) {
                    TestReminderButton(notifications: reminders.notifications, openSettings: actions.openNotificationSettings) { reminders.sendTest() }
                }
                Divider()
                // It answers the blink reminder, so it is here and not under Breaks.
                let cameraOn = model.status(now: moment.now).isCameraOn
                Row("Try a blink break", detail: cameraOn ? "10 slow blinks, counted by the camera. A finished one answers the reminder for 20 minutes."
                                                          : "The camera counts the blinks of a blink break, and it is off now.") {
                    Button("Start") { actions.startBlinkBreak() }
                        .disabled(!cameraOn)
                }
            }
            Card {
                Row("Limit", detail: "Under it, the app shows Low and can remind you.") {
                    Picker("Limit", selection: $preferences.automaticLimit) {
                        Text("Automatic").tag(true)
                        Text("Manual").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Divider()
                if preferences.automaticLimit {
                    referenceBlock
                    Divider()
                }
                Row(preferences.automaticLimit ? "Lowest limit" : "Limit",
                    detail: preferences.automaticLimit
                        ? "The automatic limit never goes under this."
                        : "A limit you choose. What studies report is under About.") {
                    HStack(spacing: 6) {
                        Text("\(preferences.floor) a minute").monospacedDigit()
                        Stepper("Blinks a minute", value: $preferences.floor, in: Preferences.floorChoices)
                    }
                }
            }
            Card {
                Row(SummaryWords.row, detail: SummaryWords.detail) {
                    Toggle(SummaryWords.row, isOn: $preferences.summaryOn)
                }
                if preferences.summaryOn {
                    Divider()
                    let held = SummaryWords.isHeldBack(hour: preferences.summaryHour, by: preferences.workingHours)
                    Row(SummaryWords.hourRow, detail: held ? SummaryWords.heldBack(hour: preferences.summaryHour)
                                                           : "The banner comes at the first minute counted from this hour on, on that day only.") {
                        Picker(SummaryWords.hourRow, selection: $preferences.summaryHour) {
                            ForEach(0..<24, id: \.self) { Text(Format.hour($0)).tag($0) }
                        }
                        .fixedSize()
                    }
                }
            }
            studiesCard
            Text("A reminder is a banner at the top right of the screen. It leaves after a few seconds and then waits in Notification Centre. Its buttons show when the pointer is over it.")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What studies report, in one line. The figure with its four bars and two dots sat
    /// here, under a control that sets a limit, and ended on "none of this is a target":
    /// it read as a verdict on the limit above it. It is whole under About.
    private var studiesCard: some View {
        Card {
            Row("What studies report",
                detail: "At a screen, groups of healthy adults average \(PublishedRates.atScreen.span) blinks a minute. That is what is typical, not a target.") {
                Button("Show") { state.tab = .sources }
            }
        }
    }

    /// Your reference: what it is, the limit it gives, and measuring it again - a decision
    /// the app never takes by itself (see `Baseline`).
    @ViewBuilder
    private var referenceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reference = preferences.reference {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your usual rate: \(Format.rate(reference.rate)) blinks a minute")
                        Text("Measured on \(Format.day(reference.measuredOn)) over \(Format.count(reference.minutes, "minute")). \(limitSentence(reference))")
                            .textStyle(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if state.measurement == nil {
                        Button("Measure Again…") { measureAgain() }
                    }
                }
                if Baseline.limitAboveUsual(reference: reference, limit: preferences.limit) {
                    // A floor to lower, not a person to warn: said with the way out.
                    Label(PublishedRates.limitAboveUsual(reference: reference, limit: preferences.limit,
                                                         canLower: preferences.floor > Preferences.floorChoices.lowerBound),
                          systemImage: "info.circle")
                        .textStyle(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.measurement == nil {
                    Text("Measured once and kept. If you blink less over the months, the limit stays and History shows the gap.")
                        .textStyle(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let calibration = Baseline.calibration(records: history.minutes)
                Text("Learning your usual rate")
                ProgressView(value: calibration.progress)
                Text("\(Format.duration(calibration.watchedSeconds)) of 3 h at the screen, on \(calibration.days) of 2 days. "
                     + "Until then the limit is \(preferences.limit) a minute. Once measured, the limit is 70% of your usual rate.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            measurementBlock
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func limitSentence(_ reference: Reference) -> String {
        let share = Int((reference.rate * Baseline.shareOfReference).rounded())
        return share >= preferences.floor
            ? "Your limit is 70% of it: \(preferences.limit) a minute."
            : "70% of it would be \(share), so the lowest limit, \(preferences.floor), applies."
    }

    @ViewBuilder
    private var measurementBlock: some View {
        switch state.measurement {
        case .proposed(let proposal):
            let newLimit = Baseline.limit(reference: proposal.measured, automatic: true, floor: preferences.floor)
            VStack(alignment: .leading, spacing: 8) {
                Text("Measured over the last week: \(Format.rate(proposal.measured.rate)) blinks a minute.")
                    .fontWeight(.semibold)
                let change = newLimit == preferences.limit
                    ? "the limit stays at \(newLimit)" : "the limit moves from \(preferences.limit) to \(newLimit)"
                if proposal.lowers {
                    // The sign is orange, the sentence is not: orange text is the hardest to read.
                    Label {
                        Text("This is lower than your usual rate. If you use it, \(change), and History stops "
                             + "showing the drop. Use it only if the old measure was wrong.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                } else {
                    Text("If you use it, \(change).")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    // Keeping is the default when the new measure would hide a decline.
                    Button("Use \(Format.rate(proposal.measured.rate))") {
                        preferences.reference = proposal.measured
                        state.measurement = nil
                    }
                    .keyboardShortcut(proposal.lowers ? nil : .defaultAction)
                    Button(proposal.current.map { "Keep \(Format.rate($0.rate))" } ?? "Cancel") { state.measurement = nil }
                        .keyboardShortcut(proposal.lowers ? .defaultAction : .cancelAction)
                }
            }
            .textStyle(.callout)
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        case .tooLittle:
            HStack(alignment: .firstTextBaseline) {
                Text("Too little was recorded in the last week to measure: 3 hours over 2 days are needed.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                // Nothing dismissed this until the window was closed.
                Button("OK") { state.measurement = nil }
                    .mainButton()
            }
        case nil:
            EmptyView()
        }
    }

    private func measureAgain() {
        let proposal = Baseline.proposal(current: preferences.reference, records: history.minutes, now: moment.now)
        state.measurement = proposal.map { .proposed($0) } ?? .tooLittle
    }

    // MARK: Your data

    private var data: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    DataPoint(symbol: "light.beacon.max", text: "The green light beside the camera means Blink is counting. Pause, in the menu-bar panel, turns the camera and the light off.")
                    DataPoint(symbol: "tablecells", text: "Kept: one line per minute, with the seconds counted and the number of blinks.")
                    DataPoint(symbol: "eye", text: "Kept from setup: the small pictures of your eyes it recorded, and the model trained on them. You can see and delete them under Model.")
                    DataPoint(symbol: "checklist", text: "Kept with a routine switched on: one line each time a reminder is shown, done, postponed or missed.")
                    DataPoint(symbol: "eye.slash", text: "Kept about breaks: one line each time a look-away break is taken or skipped, a blink break is finished or a blink reminder is shown.")
                    if state.onDisk.captures > 0 {
                        DataPoint(symbol: "record.circle", text: "Kept from Live View: \(Format.count(state.onDisk.captures, "capture")) of your eyes"
                                  + String(format: ", %.0f MB, ", state.onDisk.captureMegabytes)
                                  + "recorded with its record buttons.")
                    }
                    DataPoint(symbol: "square.and.pencil", text: "Kept with the evening question switched on: your answer, one line a day.")
                    DataPoint(symbol: "photo", text: "Never kept: what the camera sees while it counts. Each picture is read and discarded at once.")
                    DataPoint(symbol: "wifi.slash", text: "Nothing leaves this Mac. The app makes no network connection.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            // Every file the app writes, each with its size, where it is and its own Erase.
            Card {
                Row("History file", detail: "\(Format.count(history.minutes.count, "minute")) from the last \(HistoryController.daysKept) days are shown. "
                        + "The file keeps every minute since the first, and Erase removes all of them. \(Self.size(of: history.store.file))") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([history.store.file]) }
                    Button("Erase…") {
                        if Confirm.destructive(EraseWords.history(startingLimit: preferences.floor)) { model.eraseHistory() }
                    }
                    .disabled(history.minutes.isEmpty && preferences.reference == nil)
                }
                Divider()
                let log = model.routines.store.file
                Row("Routine log", detail: "What you did with your routines, one line each time. It opens in any spreadsheet. \(Self.size(of: log))") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                        .disabled(!FileManager.default.fileExists(atPath: log.path))
                    Button("Erase…") {
                        if Confirm.destructive(EraseWords.routineLog) { model.routines.eraseRecord() }
                    }
                    .disabled(!FileManager.default.fileExists(atPath: log.path))
                }
                Divider()
                let breakLog = model.care.store.file
                Row(KeptWords.fileTitle, detail: "\(KeptWords.fileDetail) \(Self.size(of: breakLog))") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([breakLog]) }
                        .disabled(!FileManager.default.fileExists(atPath: breakLog.path))
                    Button("Erase…") {
                        if Confirm.destructive(EraseWords.breakLog) { model.care.erase() }
                    }
                    .disabled(!FileManager.default.fileExists(atPath: breakLog.path))
                }
                Divider()
                let eyeNotes = model.eyeNotes.store.file
                Row(EyeNoteWords.fileTitle, detail: "\(EyeNoteWords.fileDetail) \(Self.size(of: eyeNotes))") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([eyeNotes]) }
                        .disabled(!FileManager.default.fileExists(atPath: eyeNotes.path))
                    Button("Erase…") {
                        if Confirm.destructive(EraseWords.eyeNotes) { model.eyeNotes.erase() }
                    }
                    .disabled(!FileManager.default.fileExists(atPath: eyeNotes.path))
                }
                if state.onDisk.captures > 0, let captures = files.capturesRoot {
                    Divider()
                    Row("Captures folder", detail: "Small pictures of your eyes, frame by frame, saved from Live View."
                            + String(format: " %.0f MB.", state.onDisk.captureMegabytes)) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([captures]) }
                        Button("Erase…") {
                            guard Confirm.destructive(EraseWords.captures(state.onDisk.captures)) else { return }
                            try? FileManager.default.removeItem(at: captures)
                            state.refresh(files)
                        }
                    }
                }
            }
            // Dragging the app to the Trash leaves all of the above behind.
            if let deleteEverything = actions.deleteEverythingAndQuit {
                Card {
                    Row("Remove Blink from this Mac",
                        detail: "Deletes the recordings, the model, the history, the routine log, the break log, your eye notes and every setting, then quits. Afterwards, move the app itself to the Trash.") {
                        Button("Delete Everything and Quit…") {
                            if Confirm.destructive(EraseWords.everything) { deleteEverything() }
                        }
                    }
                }
            }
        }
        .onAppear { state.refresh(files) }
    }

    /// "12 KB.", or that the file does not exist yet.
    static func size(of file: URL) -> String {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 else { return "No file yet." }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "."
    }

    // MARK: Your model

    private var modelTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Row(modelTitle, detail: modelDetail) {
                    if !model.isDemo && model.modelSource == .none {
                        Button(preferences.welcomed ? "Continue Setup…" : "Set Up…") { actions.openSetup(.resume) }
                            .mainButton()
                    }
                }
            }
            // With no model there is one thing to do, and it is the button above: adding
            // a recording or deleting what does not exist were two ways in that led nowhere.
            if !model.isDemo, model.modelSource != .none || state.onDisk.sessions > 0 || state.onDisk.captures > 0 || state.onDisk.untested {
                if model.modelSource != .none {
                    Card {
                        Row("Add a recording",
                            detail: "Two minutes in another light, on another day or with other glasses. Then the model is trained again on everything, and tested.") {
                            Button("Add a Recording…") { actions.openSetup(.addSession) }
                        }
                        Divider()
                        Row("Test it again", detail: "10 ticks, a blink at each: how many does it count where you sit now?") {
                            Button("Test Again") { actions.openSetup(.test) }
                                .disabled(!isTrainedHere)
                        }
                    }
                }
                Card {
                    Row("Recordings", detail: onDiskDetail) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([files.store.base]) }
                    }
                    if isTrainedHere, files.ownSessions {
                        Divider()
                        Row("Start again", detail: "For a model that counts badly: deletes the recordings and the model, then opens setup.") {
                            Button("Start Again…") {
                                if Confirm.destructive(EraseWords.startAgain) { deleteEverything(thenSetUp: true) }
                            }
                        }
                    }
                    Divider()
                    Row("Delete recordings and model", detail: state.deleteProblem ?? "Removes every picture of your eyes and the model trained on them. They are deleted for good, not moved to the Trash.") {
                        Button("Delete…") {
                            if Confirm.destructive(EraseWords.recordingsAndModel(deleteWarning)) { deleteEverything() }
                        }
                        .disabled(state.onDisk.sessions == 0 && state.onDisk.captures == 0 && !isTrainedHere && !state.onDisk.untested)
                    }
                }
            }
        }
        .onAppear { state.refresh(files) }
    }

    private var isTrainedHere: Bool {
        if case .trainedHere = model.modelSource { return true }
        return false
    }

    private var modelTitle: String {
        if model.isDemo { return "The demo has no model" }
        switch model.modelSource {
        case .trainedHere: return "Trained in this app, on your eyes"
        case .builtIn: return "Built into this app"
        case .given: return "Named at launch"
        case .none: return "No model yet"
        }
    }

    private var modelDetail: String {
        if model.isDemo { return "Its blinks are made up. See the Setup, in the panel, trains a real model on painted eyes." }
        switch model.modelSource {
        case .trainedHere(let info):
            var text = "On \(Format.day(info.trainedOn)), from \(Format.count(info.sessions.count, "recording")) "
                + "(\(info.pictures.formatted()) pictures)."
            if let proof = info.proof {
                text += " Its test: \(proof.found) of \(proof.of) blinks counted"
                    + (proof.found >= ProofTest.passMark ? "." : "; you chose to use it anyway.")
            }
            return text
        case .builtIn:
            return "It came with this copy of the app, put there by whoever built it."
                + (state.onDisk.untested ? " A model trained here is waiting for its test: Continue Setup." : "")
        case .given(let url):
            return url.path
        case .none:
            return state.onDisk.untested
                ? "Your model is trained but not tested yet. Until then nothing is counted."
                : "Blink learns your eyes before it can count. Setup takes about 8 minutes."
        }
    }

    private var onDiskDetail: String {
        let disk = state.onDisk
        let captures = disk.captures == 0 ? "" : " Also \(Format.count(disk.captures, "capture")) from Live View"
            + String(format: ", %.0f MB.", disk.captureMegabytes)
        guard disk.sessions > 0 else { return disk.captures == 0 ? "No recording on this Mac." : "No recording on this Mac.\(captures)" }
        return "\(Format.count(disk.sessions, "recording")), \(disk.pictures.formatted()) small pictures of your eyes, "
            + String(format: "%.0f MB.", disk.megabytes) + captures + " "
            + (files.ownSessions ? "In a folder only your account can read." : "In \(files.sessionsRoot.path), named at launch.")
    }

    private var deleteWarning: String {
        var text = files.ownSessions
            ? "Every recording\(state.onDisk.captures > 0 ? ", every capture from Live View," : "") and the model trained on them. This cannot be undone."
            : "The model trained here. The recordings are in a folder named at launch and are left alone."
        if isTrainedHere {
            text += FileManager.default.fileExists(atPath: ModelSource.builtInModel.path)
                ? " Blink goes back to the model built into it."
                : " Blink stops counting until it is set up again."
        }
        return text
    }

    private func deleteEverything(thenSetUp: Bool = false) {
        actions.closeSetup()
        Task {
            do {
                try await model.deleteModelAndRecordings(sessions: files.sessionsRoot, own: files.ownSessions,
                                                         captures: files.capturesRoot)
                state.deleteProblem = nil
            } catch {
                state.deleteProblem = "It could not be deleted: \(error.localizedDescription)"
            }
            state.refresh(files)
            if thenSetUp, state.deleteProblem == nil { actions.openSetup(.resume) }
        }
    }

    // MARK: About

    /// The version, what the app is not, where to reach the project, and where its
    /// figures come from. The whole tab scrolls, like the others.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            about
            Card {
                Row("Website and source", detail: "What the app does, how it works, and all of its code.") {
                    Button("Open") { NSWorkspace.shared.open(ProjectLinks.home) }
                }
                Divider()
                Row("Report a problem", detail: "A page where problems are listed and answered. It needs a GitHub account.") {
                    Button("Open") { NSWorkspace.shared.open(ProjectLinks.problems) }
                }
                Divider()
                Row("Check for a new version", detail: "This is version \(AppInfo.version). The page shows the latest one. The app itself never looks: it makes no network connection.") {
                    Button("Open") { NSWorkspace.shared.open(ProjectLinks.newVersion) }
                }
            }
            Text("Each of these opens in your browser.")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
            SectionTitle("Good to know")
                .padding(.top, 6)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(GoodToKnow.all, id: \.question) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.question)
                            Text(entry.answer)
                                .textStyle(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            SectionTitle("What studies report")
                .padding(.top, 6)
            Card {
                StudyRangesSection(yours: preferences.reference.map {
                    .init(label: "your usual rate \(Format.rate($0.rate))", rate: $0.rate)
                }, limit: preferences.limit)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
            Text("What the app says about blink rates comes from these studies. They describe what is typical, not what is ideal, and none of it is a diagnosis. Each one opens in your browser.")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card { SourcesList() }
            Card {
                Row("The whole review", detail: "Every study in one table, what they disagree on, and the limits of this reading.") {
                    Button("Open") { NSWorkspace.shared.open(PublishedRates.review) }
                }
            }
        }
    }

    private var about: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Blink \(AppInfo.version)")
                    .fontWeight(.semibold)
                Text("A personal project, not a medical device: its numbers are not a diagnosis. If your eyes hurt, see an eye-care professional.")
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Pieces

/// A group of rows on one background. (The Breaks tab, in its own file, uses it too.)
private typealias Card = SettingsCard
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One setting: what it is, what it means, and its control on the right.
private typealias Row = SettingsRow
struct SettingsRow<Control: View>: View {
    private let title: String
    private let detail: String
    private let control: Control

    init(_ title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // The title on the left is the visible label; the control keeps its own for VoiceOver.
            control
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct DataPoint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
