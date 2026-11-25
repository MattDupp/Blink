import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The Blink Rate tab: the reminder, the limit and your usual rate, the summary of the day.

private typealias Card = SettingsCard
private typealias Row = SettingsRow

extension SettingsView {

    // MARK: Reminders

    var remindersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Row("Remind me when I blink too little",
                    detail: "When your rate stays under the limit for \(ReminderWords.window). Left unanswered it backs off: the next after \(ReminderWords.waits), with a sound for \(ReminderWords.withSound) only. A blink break answers it.") {
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
                Row("Try a blink break", detail: cameraOn ? "\(BlinkBreak.usualTarget) slow blinks, counted by the camera. A finished one answers the reminder for \(ReminderWords.answeredFor)."
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
                        Text("Measured on \(Format.day(reference.measuredOn)) over \(Format.count(reference.minutes, "minute")). "
                             + CalibrationWords.limit(reference: reference, limit: preferences.limit, floor: preferences.floor))
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
                Text(CalibrationWords.progress(calibration, limit: preferences.limit))
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            measurementBlock
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
                Text(CalibrationWords.tooLittle)
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
}
