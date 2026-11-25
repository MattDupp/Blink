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
    /// The records' files (`KeptRecord`): their sizes are shown in the Privacy tab.
    var records: [URL] = []
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
        /// The size of each record's file; absent: no file yet.
        var recordBytes: [URL: Int64] = [:]
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
    /// The captures could not be erased: said in their row.
    @Published var capturesProblem: String?

    func reset() {
        measurement = nil
        deleteProblem = nil
        capturesProblem = nil
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
                        untested: files.store.info().map { !$0.isAccepted } ?? false,
                        recordBytes: Dictionary(uniqueKeysWithValues: files.records.compactMap { file in
                            ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64).map { (file, $0) }
                        }))
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
}

// MARK: - Pieces

/// A group of rows on one background. Every tab uses it, each in a file of its own
/// (Settings…Tab.swift, BreaksTab.swift), and the routines' settings too.
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
