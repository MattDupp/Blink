import SwiftUI
import AppKit
import BlinkCore

/// The panel under the menu-bar item: the rate now, today so far, the last hour minute
/// by minute, and the few settings.
struct MenuPanelView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var history: HistoryController
    @ObservedObject var reminders: ReminderController
    @ObservedObject var loginItem: LoginItem
    let openDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            todaySection
            HourChart(minutes: history.minutes, threshold: Double(reminders.threshold))
                .frame(height: 64)
            Divider()
            settings
            Divider()
            HStack {
                Button(model.paused ? "Resume" : "Pause") { model.setPaused(!model.paused) }
                    .disabled(model.stage != .running)
                Button("Diagnostics...") { openDiagnostics() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: Now

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.paused ? "--" : (model.ratePerMinute.map { String(format: "%.0f", $0) } ?? "--"))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(reminders.lowRate == nil ? Color.primary : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("blinks per minute")
                    .font(.headline)
                Text(stateLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stateLine: String {
        switch model.stage {
        case .starting: return "Starting the camera..."
        case .denied: return "Camera access refused: System Settings > Privacy & Security > Camera."
        case .failed(let reason): return reason
        case .running:
            if model.paused { return "Paused: the camera is off." }
            if !model.faceFound { return "No face in view." }
            if let lowRate = reminders.lowRate {
                return String(format: "Low: %.0f a minute over the last 3 minutes.", lowRate)
            }
            return model.ratePerMinute == nil ? "Watching - a rate after 20 s." : "Over the last minute watched."
        }
    }

    // MARK: Today

    private var todaySection: some View {
        let today = history.summary(of: Date(), threshold: Double(reminders.threshold))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Today")
                .font(.headline)
            PanelRow(label: "Time watched", value: duration(today.observedSeconds))
            PanelRow(label: "Blinks", value: "\(today.blinks)")
            PanelRow(label: "Average", value: today.ratePerMinute.map { String(format: "%.1f a minute", $0) } ?? "--")
            PanelRow(label: "Minutes under \(reminders.threshold) a minute",
                     value: today.ratedMinutes == 0 ? "--"
                        : "\(today.lowMinutes) of \(today.ratedMinutes) (\(100 * today.lowMinutes / today.ratedMinutes)%)")
            Text("Last hour, one bar per minute (orange = under \(reminders.threshold))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Remind me when I blink too little",
                   isOn: Binding(get: { reminders.remindersOn }, set: { reminders.setReminders($0) }))
            Stepper("Too little = under \(reminders.threshold) a minute", value: $reminders.threshold, in: 4...20)
            if reminders.remindersOn && reminders.notificationsRefused {
                Text("Notifications are off for Blink Monitor (System Settings > Notifications): a sound will play instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Start at login",
                   isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
            if let loginProblem = loginItem.problem {
                Text(loginProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PanelRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.callout)
    }
}

/// The last 60 minutes, one bar per minute: its height is that minute's blink rate.
private struct HourChart: View {
    let minutes: [MinuteRecord]
    let threshold: Double

    var body: some View {
        Canvas { context, size in
            let now = MinuteRecord.minuteStart(of: Date())
            let slot = size.width / 60
            let top = max(30.0, threshold * 2)      // the rate drawn at full height

            for record in minutes {
                let age = Int(now.timeIntervalSince(record.start) / 60)   // minutes ago
                guard age >= 0, age < 60, let rate = record.ratePerMinute else { continue }
                let height = max(2, CGFloat(min(rate, top) / top) * size.height)
                let bar = CGRect(x: CGFloat(59 - age) * slot + 0.5, y: size.height - height,
                                 width: max(slot - 1, 1), height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1),
                             with: .color(rate < threshold ? .orange : .green))
            }

            // The threshold, as a dashed line.
            let y = size.height - CGFloat(threshold / top) * size.height
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
