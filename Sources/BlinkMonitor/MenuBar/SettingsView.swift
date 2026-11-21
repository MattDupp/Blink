import SwiftUI
import AppKit
import BlinkCore

/// What the Settings window's buttons do outside of it.
struct SettingsActions {
    var startBlinkBreak: () -> Void = {}
    var openLiveView: () -> Void = {}
}

/// What the Settings window remembers while it is open.
@MainActor
final class SettingsState: ObservableObject {

    enum Tab: String, CaseIterable {
        case general = "General"
        case reminders = "Reminders"
        case breaks = "Breaks"
        case routines = "Routines"
        case data = "Your Data"
    }

    /// The outcome of "Measure Again", waiting for your decision.
    enum Measurement: Equatable {
        case proposed(Baseline.Proposal)
        case tooLittle
    }

    @Published var tab = Tab.general
    @Published var measurement: Measurement?
    @Published var confirmingErase = false

    func reset() {
        measurement = nil
        confirmingErase = false
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
            case .breaks: breaks
            case .routines: RoutineSettings(routines: model.routines, moment: moment)
            case .data: data
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
            Row("Start at login", detail: !loginItem.available ? "Not in the demo."
                    : (loginItem.problem ?? "Blink Monitor opens by itself when you log in.")) {
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
                    detail: "When your rate stays under the limit for three minutes. Never more than one every five minutes.") {
                    Toggle("Remind me when I blink too little", isOn: $preferences.remindersOn)
                }
                Divider()
                Row("See what it looks like", detail: "Shows the reminder now, with its two buttons.") {
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
                        : "People at rest blink 15 to 20 times a minute, and far less at a screen.") {
                    HStack(spacing: 6) {
                        Text("\(preferences.floor) a minute").monospacedDigit()
                        Stepper("Blinks a minute", value: $preferences.floor, in: 4...20)
                    }
                }
            }
            if reminders.notificationsRefused && (preferences.remindersOn || preferences.breakNudgesOn) {
                Label("Notifications are off for Blink Monitor in System Settings. A sound plays instead.",
                      systemImage: "bell.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    // MARK: Breaks

    private var breaks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Row("Blink break", detail: "Ten slow, full blinks, counted by the camera. Also offered when your rate is low.") {
                    Button("Start") { actions.startBlinkBreak() }
                        .disabled(!model.status(now: moment.now).isCameraOn)
                }
            }
            Card {
                Row("Remind me to look away",
                    detail: "Looking at something far away rests the eyes: 20 seconds is enough.") {
                    Toggle("Remind me to look away", isOn: $preferences.breakNudgesOn)
                }
                Divider()
                Row("After", detail: "Time at the screen without a break.") {
                    Picker("After", selection: $preferences.breakMinutes) {
                        ForEach(Preferences.breakChoices, id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    .fixedSize()
                    .disabled(!preferences.breakNudgesOn)
                }
            }
            Text("A break is 20 seconds with no face in view. The camera cannot tell where you look, so the count also starts again once a nudge has been shown.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Your data

    private var data: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    DataPoint(symbol: "tablecells", text: "Kept: one line per minute, with the time your eyes were watched and the number of blinks.")
                    DataPoint(symbol: "photo", text: "Never kept: pictures. Each camera frame is analysed in memory and dropped.")
                    DataPoint(symbol: "wifi.slash", text: "Nothing leaves this Mac. The app makes no network connection.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            Card {
                Row("History file", detail: "\(history.minutes.count.formatted()) minutes over the last \(HistoryController.daysKept) days. Any spreadsheet opens it.") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([history.store.file]) }
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

/// A group of rows on one background.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One setting: what it is, what it means, and its control on the right.
private struct Row<Control: View>: View {
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
