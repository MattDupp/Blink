import SwiftUI
import BlinkCore

/// The timer's window: the time left, and Stop.
///
/// Nobody watches it while it runs - their eyes are covered. It is there for the moment
/// before (it has started, here is how long) and the moment after (it is over, and
/// counted). The sound at the end is what carries the session.
///
/// It says nothing about how long or how warm: the length is the user's setting, and the
/// words send them to the instructions of what they use.
struct RoutineSessionView: View {
    @ObservedObject var routines: RoutineController
    @ObservedObject var session: RoutineSessionController
    /// The moment the window describes: the present, except in the screenshots.
    var moment = Moment()

    var body: some View {
        // Once a second: the clock in the ring counts down.
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1)) { _ in
            content(now: moment.now)
        }
    }

    private func content(now: Date) -> some View {
        let running = session.session
        let shown = running ?? session.finished
        let routine = routines.routines.first { $0.id == shown?.routine }
        let week = routines.days(now: now).first { $0.routine.id == shown?.routine }?.week
        return VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: running?.progress(at: now) ?? (shown == nil ? 0 : 1))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))                 // starts at the top
                if let running {
                    VStack(spacing: 0) {
                        Text(running.clock(at: now))
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("until \(Format.time(running.end))")
                            .foregroundStyle(.secondary)
                    }
                } else if shown != nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 58, weight: .bold))
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 170, height: 170)
            .padding(.top, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(running.map { "\($0.clock(at: now)) left" } ?? "Done")

            VStack(spacing: 6) {
                Text(running != nil ? (routine?.title ?? "Timer") : shown != nil ? "Done" : "No timer is running")
                    .textStyle(.title2, weight: .semibold) .multilineTextAlignment(.center)
                Text(note(running: running != nil, finished: shown != nil, week: week))
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if running != nil {
                Button("Stop") { session.stop() }
                    .help("Ends the timer without marking it done")
                    // No Escape here, on purpose: a stray key must not stop a timer that
                    // someone with covered eyes is waiting on.
            } else if shown != nil {
                Button("Close") { session.dismiss() }
                    .mainButton()
            }
        }
        .padding(24)
        .windowWidth(340, height: 356, alignment: .top)
    }

    private func note(running: Bool, finished: Bool, week: RoutineWeek?) -> String {
        if running {
            return "A sound marks the end: no need to look. The camera is paused meanwhile. "
                + "Follow your product's instructions."
        }
        guard finished else { return "Start one from the menu-bar panel." }
        let count = week.map { "\($0.done) of \($0.target) this week. " } ?? ""
        return "Marked done. \(count)The camera is on again. This window closes in \(Int(RoutineSessionController.shownDoneSeconds / 60)) minutes."
    }
}
