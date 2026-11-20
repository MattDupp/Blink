import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

/// What the panel's buttons do. The panel itself only draws; whoever shows it decides.
struct PanelActions {
    var startBlinkBreak: () -> Void = {}
    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    var quit: () -> Void = {}
}

/// What the panel remembers while it is open (SwiftUI's own `@State` needs Xcode's
/// macros, which this project builds without).
@MainActor
final class PanelState: ObservableObject {
    /// The pause choices are showing.
    @Published var choosingPause = false
    /// The bar of the last-hour chart under the pointer: how many minutes ago it was.
    @Published var hoveredMinute: Int?

    func reset() {
        choosingPause = false
        hoveredMinute = nil
    }
}

/// The panel under the menu-bar item, read from top to bottom: how you blink NOW, how
/// TODAY went, then what you can do. Settings live in their own window.
struct MenuPanelView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var history: HistoryController
    @ObservedObject var reminders: ReminderController
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: PanelState
    /// The moment the panel describes: now, except in the screenshots.
    var now = Date()
    let actions: PanelActions

    var body: some View {
        let status = model.status(now: now)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                NowSection(status: status)
                Notes(status: status, history: history, reminders: reminders, preferences: preferences, now: now)
            }
            .padding(16)
            Divider()
            TodaySection(history: history, state: state, limit: preferences.limit, now: now)
                .padding(16)
            Divider()
            ActionsSection(model: model, state: state, status: status, actions: actions)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
        }
        .frame(width: 340)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                RateReadout(rate: status.rate, tint: status.isLow ? .orange : .primary)
                Spacer(minLength: 8)
                StatusPill(text: status.label, color: status.tint)
            }
            Text(status.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        .fixedSize()
    }
}

/// The lines under the rate that are only there when they have something to say: time at
/// the screen, snoozed reminders, how you compare with your reference.
private struct Notes: View {
    let status: MonitorStatus
    @ObservedObject var history: HistoryController
    @ObservedObject var reminders: ReminderController
    @ObservedObject var preferences: Preferences
    let now: Date

    var body: some View {
        let lines = self.lines
        if !lines.isEmpty || reminders.snoozedUntil != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let until = reminders.snoozedUntil {
                    HStack(spacing: 6) {
                        NoteLine(symbol: "bell.slash", text: "Reminders snoozed until \(Format.time(until))")
                        Spacer(minLength: 4)
                        Button("Resume") { reminders.snooze(minutes: nil) }
                            .controlSize(.small)
                    }
                }
                ForEach(lines, id: \.text) { line in
                    NoteLine(symbol: line.symbol, text: line.text, tint: line.tint)
                }
            }
        }
    }

    private var lines: [(symbol: String, text: String, tint: Color)] {
        var lines: [(String, String, Color)] = []
        if preferences.breakNudgesOn, status.isCameraOn, reminders.screenMinutes >= 1 {
            lines.append(("clock", "At the screen for \(reminders.screenMinutes) min without a break", .secondary))
        }
        guard preferences.automaticLimit else { return lines }
        if let reference = preferences.reference {
            // A decline is SHOWN against the reference; the reference does not follow it.
            if let drift = Baseline.drift(reference: reference, recent: history.minutes),
               drift >= Baseline.driftWorthSaying {
                lines.append(("arrow.down.right",
                              String(format: "This week you blink %.0f%% less than your reference (%.0f a minute, %@)",
                                     drift * 100, reference.rate, Format.day(reference.measuredOn)), .orange))
            }
        } else {
            let progress = Baseline.calibration(records: history.minutes).progress
            lines.append(("gauge.with.needle",
                          "Learning your usual rate: \(Int(progress * 100))% done. Until then the limit is \(preferences.limit).",
                          .secondary))
        }
        return lines
    }
}

private struct NoteLine: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 14)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Today

private struct TodaySection: View {
    @ObservedObject var history: HistoryController
    @ObservedObject var state: PanelState
    let limit: Int
    let now: Date

    var body: some View {
        let today = history.summary(of: now, threshold: Double(limit))
        let hour = LastHour(minutes: history.minutes, current: history.currentMinute, now: now)
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
                    Text(caption(today: today, hour: hour))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                MinuteBars(hour: hour, limit: Double(limit), hovered: state.hoveredMinute) { state.hoveredMinute = $0 }
                    .frame(height: 54)
                HStack(spacing: 4) {
                    Text("60 min ago")
                    Spacer()
                    HStack(spacing: 5) {
                        DashedLine().frame(width: 18, height: 1)
                        Text("limit: \(limit) a minute")
                    }
                    Spacer()
                    Text("now")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    /// The minute under the pointer when there is one; else how today went, said as what
    /// went well ("on target") and not as a reproach ("under the limit").
    private func caption(today: DaySummary, hour: LastHour) -> String {
        if let ago = state.hoveredMinute {
            let time = Format.time(hour.start(minutesAgo: ago))
            guard let rate = hour.rate(minutesAgo: ago) else { return "\(time): not watched" }
            return String(format: "%@: %.0f a minute", time, rate) + (ago == 0 ? " so far" : "")
        }
        guard let low = today.lowShare else { return "" }
        return "\(Int(((1 - low) * 100).rounded()))% of today's minutes on target"
    }
}

/// A short piece of the chart's dashed line, for its legend.
private struct DashedLine: View {
    var body: some View {
        Canvas { context, size in
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(line, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .accessibilityHidden(true)
    }
}

/// The last 60 minutes as the chart needs them: one rate per minute, by how long ago.
struct LastHour {
    /// Index 0 = the minute in progress, 59 = fifty-nine minutes ago. Nil: not watched.
    private(set) var rates = [Double?](repeating: nil, count: 60)
    private let currentStart: Date

    init(minutes: [MinuteRecord], current: MinuteRecord?, now: Date) {
        currentStart = MinuteRecord.minuteStart(of: now)
        // The finished minutes are in order of time: the last 60 are enough to look at.
        for record in minutes.suffix(60) + [current].compactMap({ $0 }) {
            let ago = Int((currentStart.timeIntervalSince(record.start) / 60).rounded())
            if rates.indices.contains(ago) { rates[ago] = record.ratePerMinute }
        }
    }

    var isEmpty: Bool { rates.allSatisfy { $0 == nil } }

    func rate(minutesAgo: Int) -> Double? {
        rates.indices.contains(minutesAgo) ? rates[minutesAgo] : nil
    }

    func start(minutesAgo: Int) -> Date {
        currentStart.addingTimeInterval(-Double(minutesAgo) * 60)
    }

    /// Which minute a point of the chart belongs to (the newest is on the right).
    static func minutesAgo(atX x: CGFloat, width: CGFloat) -> Int {
        min(59, max(0, 59 - Int(x / (width / 60))))
    }
}

/// The last 60 minutes, one bar per minute: its height is that minute's blink rate.
/// Orange = under the limit (the dashed line). The minute in progress is drawn lighter:
/// its rate is not final.
private struct MinuteBars: View {
    let hour: LastHour
    let limit: Double
    let hovered: Int?
    /// The pointer is over the bar of that many minutes ago (nil: it left the chart).
    let onHover: (Int?) -> Void

    var body: some View {
        Canvas { context, size in
            let slot = size.width / 60
            // The rate drawn at full height: room above the tallest bar and above the line.
            let top = max(limit * 1.6, (hour.rates.compactMap { $0 }.max() ?? 0) * 1.1)

            if let hovered {
                let column = CGRect(x: CGFloat(59 - hovered) * slot, y: 0, width: slot, height: size.height)
                context.fill(Path(column), with: .color(.primary.opacity(0.12)))
            }
            for (ago, rate) in hour.rates.enumerated() {
                guard let rate else { continue }
                let height = max(2, CGFloat(min(rate, top) / top) * size.height)
                let bar = CGRect(x: CGFloat(59 - ago) * slot + 0.5, y: size.height - height,
                                 width: max(slot - 1.2, 1), height: height)
                let colour: Color = rate < limit ? .orange : .green
                context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(colour.opacity(ago == 0 ? 0.45 : 1)))
            }

            let y = size.height - CGFloat(limit / top) * size.height
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if hour.isEmpty {
                Text("Nothing recorded in the last hour yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): onHover(LastHour.minutesAgo(atX: point.x, width: geometry.size.width))
                        case .ended: onHover(nil)
                        }
                    }
            }
        }
        .accessibilityLabel("Blink rate, minute by minute, over the last hour")
    }
}

// MARK: - Actions

private struct ActionsSection: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: PanelState
    let status: MonitorStatus
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ActionTile(symbol: "eye", title: "Blink break", tint: status.isLow ? .orange : nil) {
                    actions.startBlinkBreak()
                }
                .disabled(!status.isCameraOn)
                .help("Ten slow, full blinks, counted by the camera")

                if model.isPaused {
                    ActionTile(symbol: "play.fill", title: "Resume", tint: .accentColor) { model.resume() }
                        .help("Turn the camera back on")
                } else {
                    ActionTile(symbol: "pause.fill", title: "Pause", tint: state.choosingPause ? .accentColor : nil) {
                        state.choosingPause.toggle()
                    }
                    .disabled(model.lifecycle != .running)
                    .help("Turn the camera off: its green light goes out")
                }

                ActionTile(symbol: "chart.bar.fill", title: "History") { actions.openHistory() }
                ActionTile(symbol: "gearshape.fill", title: "Settings") { actions.openSettings() }
            }

            if state.choosingPause && !model.isPaused {
                PauseChoices { duration in
                    model.pause(for: duration)
                    state.choosingPause = false
                }
            }

            HStack(spacing: 14) {
                Text("Blink Monitor \(AppInfo.version)")
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Diagnostics") { actions.openDiagnostics() }
                Button("Quit") { actions.quit() }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

/// A pause says when it ends: the four choices.
private struct PauseChoices: View {
    let choose: (PauseDuration) -> Void

    private static let labels: [(PauseDuration, String)] = [
        (.fifteenMinutes, "For 15 minutes"), (.oneHour, "For 1 hour"),
        (.untilTomorrow, "Until tomorrow"), (.untilResumed, "Until I resume"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pause the camera")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                ForEach(Self.labels, id: \.1) { duration, label in
                    Button { choose(duration) } label: {
                        Text(label).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One of the panel's four actions: a symbol over a word. `tint`: drawn as the one to press.
private struct ActionTile: View {
    let symbol: String
    let title: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
        .buttonStyle(TileStyle(tint: tint))
    }
}

private struct TileStyle: ButtonStyle {
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint ?? .primary)
            .background((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.16), in: RoundedRectangle(cornerRadius: 8))
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.6 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Shared pieces

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
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// How the app writes durations, times and days: once, so every window says them alike.
enum Format {
    /// "42 min", "2 h 05".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }

    /// "16:30".
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "18 Nov".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// When a pause ends: "16:30", or "tomorrow" for the pause that lasts until midnight.
    static func pauseEnd(_ date: Date, calendar: Calendar = .current) -> String {
        calendar.startOfDay(for: date) == date ? "tomorrow" : time(date)
    }
}
