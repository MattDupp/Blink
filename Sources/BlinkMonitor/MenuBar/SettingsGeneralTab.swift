import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The General tab: login, the menu bar, text size, the shortcut, the camera, working hours and energy.

private typealias Card = SettingsCard
private typealias Row = SettingsRow

extension SettingsView {

    // MARK: General

    var general: some View {
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
    var eveningQuestionCard: some View {
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
}
