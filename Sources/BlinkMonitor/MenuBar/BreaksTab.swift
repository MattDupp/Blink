import SwiftUI
import BlinkCore

/// The Breaks tab of the Settings window: the look-away breaks, with every number left to
/// you. (The blink break is in Blink Rate: it answers the blink reminder.)
///
/// The numbers can be set while the switch is off: one chooses first, and switches on after.
///
/// The sentence under "Remind me to look away" is built from the numbers below it
/// (`BreakWords.summary`), so it says what will happen as you change them.
struct BreaksTab: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var reminders: ReminderController
    /// The moment the window describes: the present, except in the screenshots.
    var moment = Moment()
    var openNotificationSettings: () -> Void = {}

    var body: some View {
        let plan = preferences.breakPlan
        let on = preferences.breakNudgesOn
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Row("Remind me to look away", detail: BreakWords.summary(plan)) {
                    Toggle("Remind me to look away", isOn: $preferences.breakNudgesOn)
                }
                Divider()
                Row("Start from", detail: "Ready-made settings: the sentence above says what each does. Change any number afterwards.") {
                    // A pop-up of names, ticked on the one in use. It was a menu whose
                    // lines each spelled out every number, hard to tell apart at a glance.
                    Picker("Start from", selection: Binding(get: { plan.preset },
                                                            set: { if let preset = $0 { preferences.breakPlan = preset.plan } })) {
                        ForEach(BreakPlan.Preset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(BreakPlan.Preset?.some(preset))
                                .help(BreakWords.summary(preset))
                        }
                        // Numbers that match no ready-made setting. Not a choice one can
                        // make, so it is listed only while it is the case.
                        if plan.preset == nil {
                            Divider()
                            Text(BreakWords.custom).tag(BreakPlan.Preset?.none)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                Row("See what it looks like",
                    detail: TestReminderWords.detail("Shows the break's banner now, with your numbers, marked as a test. No break starts.",
                                                     notifications: reminders.notifications)) {
                    TestReminderButton(notifications: reminders.notifications, openSettings: openNotificationSettings) { reminders.sendBreakTest() }
                }
                Divider()
                Row("Time between breaks", detail: "Counted while you are at the screen.") {
                    Stepper("Time between breaks",
                            onIncrement: { preferences.breakMinutes = BreakPlan.stepMinutes(preferences.breakMinutes, up: true) },
                            onDecrement: { preferences.breakMinutes = BreakPlan.stepMinutes(preferences.breakMinutes, up: false) })
                        .number(BreakWords.length(minutes: plan.workMinutes))
                }
                Divider()
                Row("Length of a break", detail: "Plus 5 seconds to turn away.") {
                    Stepper("Length of a break",
                            onIncrement: { preferences.breakSeconds = BreakPlan.stepSeconds(preferences.breakSeconds, up: true) },
                            onDecrement: { preferences.breakSeconds = BreakPlan.stepSeconds(preferences.breakSeconds, up: false) })
                        .number(BreakWords.length(seconds: plan.breakSeconds))
                }
                Divider()
                Row("A sound when a break starts", detail: "With its banner. Off: the banner comes in silence.") {
                    Toggle("A sound when a break starts", isOn: $preferences.breakStartSound)
                }
                Divider()
                Row("A sound when a break ends", detail: "It tells you to look back without looking at the screen. It follows the Mac's notification sound, and keeps quiet under a Focus.") {
                    Toggle("A sound when a break ends", isOn: $preferences.breakEndSound)
                }
            }
            Card {
                Row("Long break", detail: "Leave the screen. Only time with no face in view counts.") {
                    Toggle("Long break", isOn: $preferences.longBreakOn)
                }
                Divider()
                Row("A long break after", detail: "Then the short breaks are counted again.") {
                    Stepper(value: $preferences.longBreakEvery, in: BreakPlan.longEveryRange) { Text("A long break after") }
                        .number(Format.count(preferences.longBreakEvery, "short break"))
                }
                Divider()
                Row("Length of a long break", detail: "If you come back early, it waits until you leave again.") {
                    Stepper(value: $preferences.longBreakMinutes, in: BreakPlan.longRange) { Text("Length of a long break") }
                        .number(BreakWords.length(minutes: preferences.longBreakMinutes))
                }
            }
            if on, let tally = BreakWords.tally(reminders.breaks.tally(now: moment.now)) {
                Label(tally, systemImage: "checkmark.circle")
                    .font(.callout)
            }
            Text("Breaks start by themselves. The camera can tell whether you are in view, not where you look, so a break taken at your desk is taken on trust. Leaving the screen for as long as a break counts as one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private typealias Card = SettingsCard
private typealias Row = SettingsRow

private extension View {
    /// The value of a stepper, written to its left: a bare stepper shows only two arrows.
    func number(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).monospacedDigit()
            self
        }
    }
}
