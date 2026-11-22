import SwiftUI
import AppKit
import BlinkCore

/// What the Settings window's buttons do outside of it.
struct SettingsActions {
    var startBlinkBreak: () -> Void = {}
    var openLiveView: () -> Void = {}
    /// Opens the setup window: to go on, to add a session, or to take the test again.
    var openSetup: (SetupModel.Purpose) -> Void = { _ in }
    /// Closes the setup window: what it shows is about to be deleted.
    var closeSetup: () -> Void = {}
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
        case model = "Your Model"
        case data = "Your Data"
        case sources = "Sources"
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
    @Published var confirmingErase = false
    @Published var onDisk = OnDisk()
    /// Set by the screenshots, which state what is on disk instead of counting it.
    var onDiskIsStated = false
    @Published var confirmingDelete = false
    @Published var deleteProblem: String?

    func reset() {
        measurement = nil
        confirmingErase = false
        confirmingDelete = false
        deleteProblem = nil
    }

    /// Counts what is on disk again.
    func refresh(_ files: SettingsFiles) {
        guard !onDiskIsStated else { return }
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

            switch state.tab {
            case .general: general
            case .reminders: remindersTab
            case .breaks: BreaksTab(model: model, preferences: preferences, reminders: reminders, moment: moment,
                                    startBlinkBreak: actions.startBlinkBreak)
            case .routines: RoutineSettings(routines: model.routines, moment: moment)
            case .model: modelTab
            case .data: data
            case .sources: sources
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .top)
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            generalCard
            about
        }
    }

    private var generalCard: some View {
        Card {
            Row("Start at login", detail: loginItem.unavailable ?? loginItem.problem
                    ?? "Blink Monitor opens by itself when you log in.") {
                Toggle("Start at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                    .disabled(!loginItem.available)
            }
            Divider()
            Row("Show the rate in the menu bar", detail: "Off: only the eye is shown, and it changes when you blink too little.") {
                Toggle("Show the rate in the menu bar", isOn: $preferences.showRateInMenuBar)
            }
            Divider()
            Row("The menu-bar eye blinks with you", detail: "It closes for a moment at each blink the camera counts.") {
                Toggle("The menu-bar eye blinks with you", isOn: $preferences.blinkBack)
            }
            Divider()
            Row("Live View", detail: "The camera with your eyes framed, and each blink as it is counted."
                    + (model.cameraName.map { " Camera: \($0)." } ?? "")) {
                Button("Open...") { actions.openLiveView() }
            }
        }
    }

    // MARK: Reminders

    private var remindersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Row("Remind me when I blink too little",
                    detail: "When your rate stays under the limit for three minutes. Left unanswered it backs off: the next after 5, 15, 30, then 60 minutes, with a sound for the first two only. A blink break answers it.") {
                    Toggle("Remind me when I blink too little", isOn: $preferences.remindersOn)
                }
                Divider()
                Row("See what it looks like", detail: "Shows a reminder now, marked as a test. Its two buttons show when the pointer is over it, and on the test they do nothing.") {
                    Button("Send a Test Reminder") { reminders.sendTest() }
                }
            }
            Card {
                Row("Limit", detail: "Under it, you are blinking too little.") {
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
                Row(preferences.automaticLimit ? "Never under" : "Too little is under",
                    detail: preferences.automaticLimit
                        ? "The automatic limit cannot go under this, whatever your reference."
                        : "A limit you choose. The picture below shows what studies report.") {
                    HStack(spacing: 6) {
                        Text("\(preferences.floor) a minute").monospacedDigit()
                        Stepper("Blinks a minute", value: $preferences.floor, in: Preferences.floorChoices)
                    }
                }
            }
            studiesCard
            if reminders.notificationsRefused && (preferences.remindersOn || preferences.breakNudgesOn) {
                Label("Notifications are off for Blink Monitor in System Settings. A sound plays instead.",
                      systemImage: "bell.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What studies report, next to the limit it helps to choose. It is shown, and that is
    /// all: the limit comes from your own reference and your floor (see `PublishedRates`).
    private var studiesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("What studies report")
                    Spacer(minLength: 12)
                    Button("Sources") { state.tab = .sources }
                        .controlSize(.small)
                }
                StudyRangesSection(yours: preferences.reference.map {
                    .init(label: String(format: "your reference %.1f", $0.rate), rate: $0.rate)
                }, limit: preferences.limit)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
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
                        Text(String(format: "Your reference: %.1f blinks a minute", reference.rate))
                        Text("Measured on \(Format.day(reference.measuredOn)) over \(reference.minutes) minutes. \(limitSentence(reference))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if state.measurement == nil {
                        Button("Measure Again...") { measureAgain() }
                    }
                }
                if Baseline.limitAboveUsual(reference: reference, limit: preferences.limit) {
                    // A floor to lower, not a person to warn: said with the way out.
                    Label(PublishedRates.limitAboveUsual(reference: reference, limit: preferences.limit,
                                                         canLower: preferences.floor > Preferences.floorChoices.lowerBound),
                          systemImage: "info.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.measurement == nil {
                    Text("It stays where it was measured. If you blink less over the months, the limit does not go down with you: the History window shows the gap instead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                let calibration = Baseline.calibration(records: history.minutes)
                Text("Learning your usual rate")
                ProgressView(value: calibration.progress)
                Text("\(Format.duration(calibration.watchedSeconds)) of 3 h watched, on \(calibration.days) of 2 days. "
                     + "Until then the limit is \(preferences.limit) a minute. Once measured, the limit is 70% of your usual rate.")
                    .font(.callout)
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
            ? "The limit is \(preferences.limit) a minute: 70% of it."
            : "70% of it would be \(share): your floor of \(preferences.floor) applies."
    }

    @ViewBuilder
    private var measurementBlock: some View {
        switch state.measurement {
        case .proposed(let proposal):
            let newLimit = Baseline.limit(reference: proposal.measured, automatic: true, floor: preferences.floor)
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: "Measured over the last week: %.1f blinks a minute.", proposal.measured.rate))
                    .fontWeight(.semibold)
                let change = newLimit == preferences.limit
                    ? "the limit stays at \(newLimit)" : "the limit moves from \(preferences.limit) to \(newLimit)"
                if proposal.lowers {
                    Label("This is lower than your reference. If you adopt it, \(change), and the decline the reference "
                          + "is there to show is hidden. Adopt it only if the old one was measured wrongly.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("If you adopt it, \(change).")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(proposal.current.map { String(format: "Keep %.1f", $0.rate) } ?? "Cancel") { state.measurement = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(String(format: "Adopt %.1f", proposal.measured.rate)) {
                        preferences.reference = proposal.measured
                        state.measurement = nil
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        case .tooLittle:
            Text("Too little was recorded in the last week to measure: three hours over two days are needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
                    DataPoint(symbol: "tablecells", text: "Kept: one line per minute, with the time your eyes were watched and the number of blinks.")
                    DataPoint(symbol: "eye", text: "Kept from setup: the small pictures of your eyes it recorded, and the model trained on them. Your Model shows them and deletes them.")
                    if state.onDisk.captures > 0 {
                        DataPoint(symbol: "record.circle", text: "Kept from Live View: \(state.onDisk.captures) capture\(state.onDisk.captures == 1 ? "" : "s") of your eyes"
                                  + String(format: ", %.0f MB, ", state.onDisk.captureMegabytes)
                                  + "recorded with its record buttons. Your Model deletes them with the recordings.")
                    }
                    DataPoint(symbol: "photo", text: "Never kept: what the camera sees while it counts. Each frame is analysed in memory and dropped.")
                    DataPoint(symbol: "wifi.slash", text: "Nothing leaves this Mac. The app makes no network connection.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            Card {
                Row("History file", detail: "\(history.minutes.count.formatted()) minutes over the last \(HistoryController.daysKept) days. Any spreadsheet opens it.") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([history.store.file]) }
                }
                if state.onDisk.captures > 0, let captures = files.capturesRoot {
                    Divider()
                    Row("Captures folder", detail: "Small pictures of your eyes, frame by frame, saved from Live View. Settings > Your Model > Delete removes them.") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([captures]) }
                    }
                }
                Divider()
                if state.confirmingErase {
                    Row("Erase every recorded minute?", detail: "The reference measured from them goes too. This cannot be undone.") {
                        Button("Cancel") { state.confirmingErase = false }
                            .keyboardShortcut(.cancelAction)
                        Button("Erase", role: .destructive) {
                            model.eraseHistory()
                            state.confirmingErase = false
                        }
                    }
                } else {
                    Row("Erase history", detail: "Removes every recorded minute, and the reference measured from them.") {
                        Button("Erase...") { state.confirmingErase = true }
                            .disabled(history.minutes.isEmpty && preferences.reference == nil)
                    }
                }
            }
        }
    }

    // MARK: Your model

    private var modelTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Row(modelTitle, detail: modelDetail) {
                    if !model.isDemo && model.modelSource == .none {
                        Button(preferences.welcomed ? "Continue Setup..." : "Set Up...") { actions.openSetup(.resume) }
                    }
                }
            }
            if !model.isDemo {
                Card {
                    Row("Add a session",
                        detail: "Two minutes in another light, on another day or with other glasses. Then the model is trained again on everything, and tested.") {
                        Button("Add a Session...") { actions.openSetup(.addSession) }
                    }
                    Divider()
                    Row("Test it again", detail: "Ten ticks, a blink at each: how many does it count where you sit now?") {
                        Button("Test...") { actions.openSetup(.test) }
                            .disabled(!isTrainedHere)
                    }
                }
                Card {
                    Row("Recordings", detail: onDiskDetail) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([files.store.base]) }
                    }
                    Divider()
                    if state.confirmingDelete {
                        Row("Delete the recordings and the model?", detail: deleteWarning) {
                            Button("Cancel") { state.confirmingDelete = false }
                                .keyboardShortcut(.cancelAction)
                            Button("Delete", role: .destructive) { deleteEverything() }
                        }
                    } else {
                        Row("Delete recordings and model", detail: state.deleteProblem ?? "Removes every picture of your eyes and the model trained on them. For good, not to the Trash.") {
                            Button("Delete...") { state.confirmingDelete = true }
                                .disabled(state.onDisk.sessions == 0 && state.onDisk.captures == 0 && !isTrainedHere && !state.onDisk.untested)
                        }
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
            var text = "On \(Format.day(info.trainedOn)), from \(info.sessions.count) session\(info.sessions.count == 1 ? "" : "s") "
                + "(\(info.pictures.formatted()) pictures), in \(Int(info.seconds.rounded())) s."
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
                ? "A model was trained and waits for its test. Until then nothing is counted."
                : "Blink Monitor reads your eyes with a model trained on them. Setup makes it in about six minutes."
        }
    }

    private var onDiskDetail: String {
        let disk = state.onDisk
        let captures = disk.captures == 0 ? "" : " Also \(disk.captures) capture\(disk.captures == 1 ? "" : "s") from Live View"
            + String(format: ", %.0f MB.", disk.captureMegabytes)
        guard disk.sessions > 0 else { return disk.captures == 0 ? "No recording on this Mac." : "No session on this Mac.\(captures)" }
        return "\(disk.sessions) session\(disk.sessions == 1 ? "" : "s"), \(disk.pictures.formatted()) small pictures of your eyes, "
            + String(format: "%.0f MB.", disk.megabytes) + captures + " "
            + (files.ownSessions ? "In a folder only your account can read." : "In \(files.sessionsRoot.path), named at launch.")
    }

    private var deleteWarning: String {
        var text = files.ownSessions
            ? "Every recording\(state.onDisk.captures > 0 ? ", every capture from Live View," : "") and the model trained on them. This cannot be undone."
            : "The model trained here. The recordings are in a folder named at launch and are left alone."
        if isTrainedHere {
            text += FileManager.default.fileExists(atPath: ModelSource.builtInModel.path)
                ? " Blink Monitor goes back to the model built into it."
                : " Blink Monitor stops counting until it is set up again."
        }
        return text
    }

    private func deleteEverything() {
        state.confirmingDelete = false
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
        }
    }

    // MARK: Sources

    /// Where the app's figures come from. A list that scrolls: nine papers with what each
    /// found do not fit a window that small screens can show whole.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What the app says about blink rates comes from these studies. They describe what is typical, not what is ideal, and none of it is a diagnosis. Each one opens in your browser.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Card { SourcesList() }
            }
            .frame(height: 380)
            Card {
                Row("The whole review", detail: "Every study in one table, what they disagree on, and the limits of this reading.") {
                    Button("Open") { NSWorkspace.shared.open(PublishedRates.review) }
                }
            }
        }
    }

    // MARK: About

    private var about: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Blink Monitor \(AppInfo.version)")
                    .fontWeight(.semibold)
                Text("A personal project, not a medical device: its numbers are not a diagnosis. If your eyes hurt, see an eye-care professional.")
                    .font(.callout)
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
                    .font(.callout)
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
