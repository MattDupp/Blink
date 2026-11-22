import SwiftUI
import BlinkCore

/// The Breaks tab of the Settings window: the blink break, and the look-away breaks with
/// every number left to you.
///
/// The sentence under "Remind me to look away" is built from the numbers below it
/// (`BreakWords.summary`), so it says what will happen as you change them.
struct BreaksTab: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var reminders: ReminderController
    /// The moment the window describes: the present, except in the screenshots.
    var moment = Moment()
    var startBlinkBreak: () -> Void = {}

    var body: some View {
        let plan = preferences.breakPlan
        let on = preferences.breakNudgesOn
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Row("Blink Break", detail: "Ten slow, full blinks, counted by the camera. Also offered when your rate is low.") {
                    Button("Start") { startBlinkBreak() }
                        .disabled(!model.status(now: moment.now).isCameraOn)
                }
            }
            Card {
                Row("Remind me to look away", detail: BreakWords.summary(plan)) {
                    Toggle("Remind me to look away", isOn: $preferences.breakNudgesOn)
                }
                Divider()
                Row("Start from", detail: "Ready-made settings. Change any number afterwards.") {
                    Menu(plan.preset?.rawValue ?? "Your own") {
                        ForEach(BreakPlan.Preset.allCases, id: \.self) { preset in
                            Button(BreakWords.summary(preset)) { preferences.breakPlan = preset.plan }
                        }
                    }
                    .fixedSize()
                }
                Divider()
                Row("Time between breaks", detail: "At the screen, with a face in view.") {
                    Stepper(value: $preferences.breakMinutes, in: BreakPlan.workRange, step: preferences.breakMinutes < 10 ? 1 : 5) {
                        Text("Time between breaks")
                    }
                    .number("\(plan.workMinutes) min")
                }
                Divider()
                Row("Length of a break", detail: "Five seconds are added to turn away.") {
                    Stepper(value: $preferences.breakSeconds, in: BreakPlan.breakRange, step: preferences.breakSeconds < 60 ? 5 : 15) {
                        Text("Length of a break")
                    }
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
            .disabled(!on)
            Card {
                Row("Long break", detail: "Leave the screen. Only time with no face in view counts.") {
                    Toggle("Long break", isOn: $preferences.longBreakOn)
                }
                Divider()
                Row("After", detail: "Short breaks before a long one.") {
                    Stepper(value: $preferences.longBreakEvery, in: BreakPlan.longEveryRange) { Text("After") }
                        .number(preferences.longBreakEvery == 1 ? "1 break" : "\(preferences.longBreakEvery) breaks")
                        .disabled(!preferences.longBreakOn)
                }
                Divider()
                Row("Length of a long break", detail: "Back early, the count waits for you to leave again.") {
                    Stepper(value: $preferences.longBreakMinutes, in: BreakPlan.longRange) { Text("Length of a long break") }
                        .number(BreakWords.length(minutes: preferences.longBreakMinutes))
                        .disabled(!preferences.longBreakOn)
                }
            }
            .disabled(!on)
            if on, let tally = BreakWords.tally(reminders.breaks.tally(now: moment.now)) {
                Label(tally, systemImage: "checkmark.circle")
                    .font(.callout)
            }
            Text("A break starts by itself and there is nothing to watch. The camera sees whether a face is in view, not where you look: a break with your face in view is taken on trust, and one with no face in view is counted as away from the screen. Leaving for as long as a break counts as one, and the time starts again when you are back.")
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
