import SwiftUI
import BlinkCore

/// The blink break window: ten slow, full blinks, counted as the camera sees them.
///
/// Why an exercise at all: at a screen people blink less AND less completely - the lid
/// comes down part of the way. A few deliberate, complete blinks spread the tear film
/// again. The ring fills with each one, and a sound marks it, because your eyes are closed
/// at that moment.
struct BlinkBreakView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var blinkBreak: BlinkBreakController
    /// The moment the window describes: now, except in the screenshots.
    var now = Date()

    var body: some View {
        let exercise = blinkBreak.exercise ?? BlinkBreak()
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: exercise.progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))                 // starts at the top
                    .animation(.easeOut(duration: 0.3), value: exercise.count)
                // A soft disc while the camera reads your eyes as closed: it is working.
                Circle()
                    .fill(Color.green.opacity(model.live.eyesClosed && !exercise.isDone ? 0.14 : 0))
                    .padding(14)
                if exercise.isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 58, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    VStack(spacing: -2) {
                        Text("\(exercise.count)")
                            .font(.system(size: 60, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("of \(exercise.target)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 170, height: 170)
            .padding(.top, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(exercise.count) of \(exercise.target) blinks")

            VStack(spacing: 6) {
                Text(exercise.isDone ? "Done" : "Close your eyes gently, hold, open")
                    .font(.system(size: 17, weight: .semibold))
                Text(note(done: exercise.isDone))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 340, height: 312, alignment: .top)
    }

    /// What to do - or why nothing is being counted.
    private func note(done: Bool) -> String {
        if done { return "\(blinkBreak.exercise?.target ?? 10) full blinks. This window closes by itself." }
        switch model.status(now: now) {
        case .watching, .low:
            return "Slowly, all the way down. A sound marks each blink: no need to look."
        case .noFace:
            return "No face in view: the camera cannot count for now."
        case .paused:
            return "The camera is paused, so nothing is counted. Resume from the menu bar."
        case .starting, .cameraRefused, .failed:
            return "The camera is not running, so nothing is counted."
        }
    }
}
