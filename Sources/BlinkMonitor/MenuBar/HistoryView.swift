import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

/// What the History window remembers while it is open.
@MainActor
final class HistoryState: ObservableObject {
    /// The day shown hour by hour (the start of that day); nil = today.
    @Published var selectedDay: Date?
}

/// The history window: your last seven days, any of them hour by hour, and the week as
/// one picture.
///
/// The question it answers is "WHEN do I blink too little?". One figure for a day hides it;
/// the hours show it (typically: the stretch of deep concentration in the afternoon).
struct HistoryView: View {
    @ObservedObject var history: HistoryController
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: HistoryState
    /// The moment the window describes: the present, except in the screenshots.
    var moment = Moment()

    private var limit: Double { Double(preferences.limit) }

    var body: some View {
        AtPresent(moment: moment) { now in window(now: now) }
    }

    private func window(now: Date) -> some View {
        let calendar = Calendar.current
        let days = history.lastDays(7, threshold: limit, now: now)
        let today = calendar.startOfDay(for: now)
        let selected = state.selectedDay ?? today
        let weekRecords = days.flatMap { history.records(on: $0.day) }
        let week = DaySummary(records: weekRecords, threshold: limit)

        // 44: the title bar. On a screen too low for the whole window, it scrolls.
        return ScrollsWhenTall(reserved: 44) { VStack(alignment: .leading, spacing: 18) {
            if weekRecords.isEmpty {
                NothingYet()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Last 7 days")
                    HStack(spacing: 8) {
                        StatTile(value: Format.duration(week.observedSeconds), caption: "at the screen")
                        StatTile(value: week.ratePerMinute.map { String(format: "%.1f", $0) } ?? "--", caption: "blinks a minute")
                        StatTile(value: week.lowShare.map { "\(Int(((1 - $0) * 100).rounded()))%" } ?? "--",
                                 caption: "of minutes above your limit")
                    }
                    BarChart(bars: days.map { day in
                        BarChart.Bar(label: day.day.formatted(.dateTime.weekday(.abbreviated)), value: day.summary.ratePerMinute)
                    }, threshold: limit, showValues: true,
                             selected: days.firstIndex { $0.day == selected }) { state.selectedDay = days[$0].day }
                        .frame(height: 140)
                        .help("Click a day to see it hour by hour")
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionTitle(selected == today ? "Today, hour by hour" : "\(selected.formatted(.dateTime.weekday(.wide).day().month(.wide))), hour by hour")
                        Spacer()
                        DayStepper(days: days.map(\.day), selected: selected) { state.selectedDay = $0 }
                    }
                    BarChart(bars: history.hours(of: selected, threshold: limit).enumerated().map { hour, summary in
                        BarChart.Bar(label: hour % 3 == 0 ? "\(hour)" : "", value: summary.ratePerMinute)
                    }, threshold: limit, showValues: false)
                        .frame(height: 100)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("The week, by hour of the day")
                    HeatMap(days: days.map(\.day), rates: Insights.heatMap(records: weekRecords, days: days.map(\.day)),
                            limit: limit, selected: selected)
                }

                let findings = self.findings(days: days, weekRecords: weekRecords, week: week)
                if !findings.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        SectionTitle("What stands out")
                        ForEach(findings, id: \.text) { finding in
                            Label(finding.text, systemImage: finding.symbol)
                                .foregroundStyle(finding.tint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.callout)
                }

                HStack {
                    Label("Orange: under \(preferences.limit) blinks a minute, your limit.", systemImage: "square.fill")
                        .labelStyle(LegendStyle(color: .orange))
                    Spacer()
                    Button("Show Data File") { NSWorkspace.shared.activateFileViewerSelecting([history.store.file]) }
                        .help("One line per minute, in a file any spreadsheet opens. No picture is ever stored.")
                }
                .font(.callout)
            }
        }
        .padding(20)
        }
        .frame(width: 620)
    }

    /// The few sentences the numbers support: your lowest hours, how you compare with your
    /// reference, your best and lowest day, and where your week sits against published studies.
    private func findings(days: [(day: Date, summary: DaySummary)], weekRecords: [MinuteRecord],
                          week: DaySummary) -> [(symbol: String, text: String, tint: Color)] {
        var findings: [(String, String, Color)] = []

        let lowest = Insights.lowestHours(records: weekRecords)
        if lowest.count == 2 {
            findings.append(("clock", String(format: "Your lowest hours: %d:00 (%.1f a minute) and %d:00 (%.1f).",
                                             lowest[0].hour, lowest[0].rate, lowest[1].hour, lowest[1].rate), .primary))
        }

        if preferences.automaticLimit, let reference = preferences.reference,
           let drift = Baseline.drift(reference: reference, recent: weekRecords) {
            let measured = String(format: "your usual rate of %.1f a minute, measured on %@", reference.rate, Format.day(reference.measuredOn))
            if drift >= Baseline.driftWorthSaying {
                findings.append(("arrow.down.right", String(format: "This week you blink %.0f%% less than %@. The limit has not moved.", drift * 100, measured), .orange))
            } else if drift <= -Baseline.driftWorthSaying {
                findings.append(("arrow.up.right", String(format: "This week you blink %.0f%% more than %@.", -drift * 100, measured), .primary))
            } else {
                findings.append(("equal", "This week matches \(measured).", .primary))
            }
        }

        let rated = days.compactMap { day in day.summary.ratePerMinute.map { (day: day.day, rate: $0) } }
        if rated.count >= 2, let best = rated.max(by: { $0.rate < $1.rate }), let worst = rated.min(by: { $0.rate < $1.rate }) {
            findings.append(("calendar", String(format: "Highest day: %@ (%.1f a minute). Lowest: %@ (%.1f).",
                                                best.day.formatted(.dateTime.weekday(.wide)), best.rate,
                                                worst.day.formatted(.dateTime.weekday(.wide)), worst.rate), .primary))
        }

        // Said in the same quiet colour wherever the week falls: a range from studies is
        // neither good nor bad, and only your own limit turns anything orange. (The picture
        // of the three ranges is in Settings: here it made this window taller than a
        // 14-inch screen.)
        if let comparison = PublishedRates.comparison(of: week) {
            findings.append(("book", comparison.sentence + " " + PublishedRates.whereTheSourcesAre, .primary))
        }
        return findings
    }
}

/// What a new install shows instead of seven empty charts.
private struct NothingYet: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("Nothing recorded yet")
                .font(.system(size: 17, weight: .semibold))
            Text("One line is kept for every minute counted. After a few minutes this window shows your days, each of them hour by hour, and the hours when your rate drops.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// The two arrows that move the hour-by-hour chart from day to day.
private struct DayStepper: View {
    let days: [Date]
    let selected: Date
    let select: (Date) -> Void

    var body: some View {
        let index = days.firstIndex(of: selected) ?? days.count - 1
        HStack(spacing: 2) {
            Button { select(days[index - 1]) } label: { Image(systemName: "chevron.left") }
                .disabled(index <= 0)
                .accessibilityLabel("Previous day")
            Button { select(days[index + 1]) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= days.count - 1)
                .accessibilityLabel("Next day")
        }
        .controlSize(.small)
    }
}

private struct LegendStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// One row per day, one cell per hour: the week at a glance. A cell's colour says on which
/// side of the limit that hour was, its strength how far from it.
private struct HeatMap: View {
    let days: [Date]
    /// `[day][hour]`, nil where too little was watched.
    let rates: [[Double?]]
    let limit: Double
    let selected: Date

    private let rowHeight: CGFloat = 17
    private let labelWidth: CGFloat = 38

    var body: some View {
        Canvas { context, size in
            let cell = (size.width - labelWidth) / 24
            for (row, day) in days.enumerated() {
                let y = CGFloat(row) * rowHeight
                let label = Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption.weight(day == selected ? .bold : .regular))
                    .foregroundStyle(day == selected ? Color.primary : Color.secondary)
                context.draw(label, at: CGPoint(x: 0, y: y + rowHeight / 2), anchor: .leading)

                for hour in 0..<24 {
                    let rect = CGRect(x: labelWidth + CGFloat(hour) * cell + 1, y: y + 1, width: cell - 2, height: rowHeight - 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(colour(rates[row][hour])))
                }
            }
            for hour in stride(from: 0, to: 24, by: 3) {
                context.draw(Text("\(hour)").font(.caption).foregroundStyle(.secondary),
                             at: CGPoint(x: labelWidth + (CGFloat(hour) + 0.5) * cell, y: CGFloat(days.count) * rowHeight + 8))
            }
        }
        .frame(height: CGFloat(days.count) * rowHeight + 16)
        .accessibilityLabel("Blink rate for every hour of the last seven days")
    }

    private func colour(_ rate: Double?) -> Color {
        guard let rate else { return .primary.opacity(0.05) }       // not watched
        let distance = min(1, abs(rate - limit) / max(limit, 1) * 2)
        return (rate < limit ? Color.orange : Color.green).opacity(0.35 + 0.65 * distance)
    }
}

/// A plain bar chart: one bar per value (nil = nothing recorded), a dashed threshold line.
/// With `onSelect`, a click on a bar's column chooses it, and `selected` is drawn as chosen.
struct BarChart: View {

    struct Bar {
        let label: String
        let value: Double?
    }

    let bars: [Bar]
    let threshold: Double
    let showValues: Bool
    var selected: Int?
    var onSelect: ((Int) -> Void)?

    var body: some View {
        Canvas { context, size in
            let labelHeight: CGFloat = 16
            let valueHeight: CGFloat = showValues ? 16 : 0
            let plot = CGRect(x: 0, y: valueHeight, width: size.width, height: size.height - labelHeight - valueHeight)
            let top = max(threshold * 1.8, (bars.compactMap(\.value).max() ?? 0) * 1.1, 1)
            let slot = plot.width / CGFloat(max(bars.count, 1))
            let barWidth = min(slot * 0.62, 46)

            if let selected, bars.indices.contains(selected) {
                let column = CGRect(x: CGFloat(selected) * slot + 3, y: 0, width: slot - 6, height: size.height)
                context.fill(Path(roundedRect: column, cornerRadius: 6), with: .color(.primary.opacity(0.07)))
            }

            // The threshold first, so the bars are drawn over it.
            let lineY = plot.maxY - CGFloat(threshold / top) * plot.height
            var line = Path()
            line.move(to: CGPoint(x: 0, y: lineY))
            line.addLine(to: CGPoint(x: size.width, y: lineY))
            context.stroke(line, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            for (index, bar) in bars.enumerated() {
                let centre = (CGFloat(index) + 0.5) * slot
                if let value = bar.value {
                    let height = max(3, CGFloat(value / top) * plot.height)
                    let rect = CGRect(x: centre - barWidth / 2, y: plot.maxY - height, width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(4, barWidth / 3)),
                                 with: .color(value < threshold ? .orange : .green))
                    if showValues {
                        // Above the bar - or above the limit line, when that line would
                        // otherwise run through the figures.
                        let crossed = lineY < rect.minY && lineY > rect.minY - 18
                        context.draw(Text(String(format: "%.1f", value)).font(.caption.weight(.semibold)),
                                     at: CGPoint(x: centre, y: (crossed ? lineY : rect.minY) - 9))
                    }
                } else {
                    // Nothing recorded: a faint mark, so the gap reads as "no data", not "zero".
                    let rect = CGRect(x: centre - barWidth / 2, y: plot.maxY - 2, width: barWidth, height: 2)
                    context.fill(Path(rect), with: .color(.secondary.opacity(0.25)))
                }
                if !bar.label.isEmpty {
                    let chosen = index == selected
                    context.draw(Text(bar.label).font(.caption.weight(chosen ? .bold : .regular))
                                    .foregroundStyle(chosen ? Color.primary : Color.secondary),
                                 at: CGPoint(x: centre, y: size.height - labelHeight / 2 + 1))
                }
            }
        }
        .overlay {
            if let onSelect {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { point in
                            let index = Int(point.x / (geometry.size.width / CGFloat(max(bars.count, 1))))
                            if bars.indices.contains(index) { onSelect(index) }
                        }
                }
            }
        }
    }
}
