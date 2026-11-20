import SwiftUI
import AppKit
import BlinkCore

/// What the panel's buttons do. The panel itself only draws; whoever shows it decides.
struct PanelActions {
    var openHistory: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    var quit: () -> Void = {}
}

/// The panel under the menu-bar item, read from top to bottom:
/// how you blink NOW, how TODAY went, then the reminder settings and the actions.
struct MenuPanelView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var history: HistoryController
    @ObservedObject var reminders: ReminderController
    @ObservedObject var loginItem: LoginItem
    /// The moment the panel describes: now, except in the screenshots.
    var now = Date()
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NowSection(status: model.status(now: now))
                .padding(16)
            Divider()
            TodaySection(history: history, threshold: reminders.threshold, now: now)
                .padding(16)
            Divider()
            ReminderSection(reminders: reminders)
                .padding(16)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 340)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(model.paused ? "Resume" : "Pause") { model.setPaused(!model.paused) }
                .disabled(model.lifecycle != .running)
                .help(model.paused ? "Turn the camera back on" : "Turn the camera off: its green light goes out")
            Button("History") { actions.openHistory() }
            Spacer()
            Menu {
                Toggle("Start at Login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                Button("Diagnostics...") { actions.openDiagnostics() }
                Divider()
                Text("Blink Monitor \(AppInfo.version)")
                Button("Quit Blink Monitor") { actions.quit() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - Now

private struct NowSection: View {
    let status: MonitorStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.rateText)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isLow ? Color.orange : Color.primary)
                    .contentTransition(.numericText())
                Text("blinks\na minute")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(-2)
                Spacer()
                StatusPill(text: status.label, color: status.tint)
            }
            .accessibilityElement(children: .combine)

            Text(status.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isLow: Bool {
        if case .low = status { return true }
        return false
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Today

private struct TodaySection: View {
    @ObservedObject var history: HistoryController
    let threshold: Int
    let now: Date

    var body: some View {
        let today = history.summary(of: now, threshold: Double(threshold))
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Today")
            HStack(spacing: 8) {
                StatTile(value: Format.duration(today.observedSeconds), caption: "watched")
                StatTile(value: today.blinks.formatted(), caption: "blinks")
                StatTile(value: today.ratePerMinute.map { String(format: "%.1f", $0) } ?? "--", caption: "a minute")
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Last hour").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let share = today.lowShare {
                        Text("\(Int((share * 100).rounded()))% of today's minutes under \(threshold)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                MinuteBars(minutes: history.minutes, threshold: Double(threshold), now: now)
                    .frame(height: 54)
            }
        }
    }
}

struct SectionTitle: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.6)
    }
}

struct StatTile: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

enum Format {
    /// "42 min", "2 h 05".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }
}

/// The last 60 minutes, one bar per minute: its height is that minute's blink rate.
/// Orange = under the threshold (the dashed line).
private struct MinuteBars: View {
    let minutes: [MinuteRecord]
    let threshold: Double
    let now: Date

    var body: some View {
        Canvas { context, size in
            let current = MinuteRecord.minuteStart(of: now)
            let slot = size.width / 60
            let shown = minutes.filter { current.timeIntervalSince($0.start) < 3600 }.compactMap(\.ratePerMinute)
            // The rate drawn at full height: room above the tallest bar and above the line.
            let top = max(threshold * 1.6, (shown.max() ?? 0) * 1.1)

            for record in minutes {
                let age = Int(current.timeIntervalSince(record.start) / 60)   // minutes ago
                guard age >= 0, age < 60, let rate = record.ratePerMinute else { continue }
                let height = max(2, CGFloat(min(rate, top) / top) * size.height)
                let bar = CGRect(x: CGFloat(59 - age) * slot + 0.5, y: size.height - height,
                                 width: max(slot - 1.2, 1), height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1.5),
                             with: .color(rate < threshold ? .orange : .green))
            }

            let y = size.height - CGFloat(threshold / top) * size.height
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Blink rate, minute by minute, over the last hour")
    }
}

// MARK: - Reminders

private struct ReminderSection: View {
    @ObservedObject var reminders: ReminderController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Reminders")
            Toggle("Remind me when I blink too little",
                   isOn: Binding(get: { reminders.remindersOn }, set: { reminders.setReminders($0) }))

            Stepper(value: $reminders.threshold, in: 4...20) {
                Text("Too little is under ")
                    + Text("\(reminders.threshold)").fontWeight(.semibold).monospacedDigit()
                    + Text(" a minute")
            }
            .help("People at rest blink about 15 to 20 times a minute, and much less at a screen. Adjust to what suits you.")

            if reminders.remindersOn {
                HStack {
                    if let until = reminders.snoozedUntil {
                        Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Resume") { reminders.snooze(minutes: nil) }
                            .controlSize(.small)
                    } else {
                        Text("Not now?")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu("Snooze") {
                            Button("For 30 minutes") { reminders.snooze(minutes: 30) }
                            Button("For 1 hour") { reminders.snooze(minutes: 60) }
                            Button("For 2 hours") { reminders.snooze(minutes: 120) }
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                .font(.callout)
            }

            if reminders.remindersOn && reminders.notificationsRefused {
                Label("Notifications are off for Blink Monitor in System Settings. A sound plays instead.",
                      systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
