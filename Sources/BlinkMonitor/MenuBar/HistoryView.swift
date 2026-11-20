import SwiftUI
import AppKit
import BlinkCore

/// The history window: your last seven days, and today hour by hour.
///
/// The question it answers is "WHEN do I blink too little?". One figure for a day hides it;
/// the hours show it (typically: the stretch of deep concentration in the afternoon).
struct HistoryView: View {
    @ObservedObject var history: HistoryController
    @ObservedObject var reminders: ReminderController
    /// The moment the window describes: now, except in the screenshots.
    var now = Date()

    private var threshold: Double { Double(reminders.threshold) }

    var body: some View {
        let days = history.lastDays(7, threshold: threshold, now: now)
        let hours = history.hours(of: now, threshold: threshold)
        let week = DaySummary(records: days.flatMap { history.records(on: $0.day) }, threshold: threshold)

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Last 7 days")
                HStack(spacing: 8) {
                    StatTile(value: Format.duration(week.observedSeconds), caption: "watched")
                    StatTile(value: week.ratePerMinute.map { String(format: "%.1f", $0) } ?? "--", caption: "blinks a minute")
                    StatTile(value: week.lowShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "--",
                             caption: "of minutes under \(reminders.threshold)")
                }
                BarChart(bars: days.map { day in
                    BarChart.Bar(label: day.day.formatted(.dateTime.weekday(.abbreviated)),
                                 value: day.summary.ratePerMinute)
                }, threshold: threshold, showValues: true)
                    .frame(height: 150)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Today, hour by hour")
                BarChart(bars: hours.enumerated().map { hour, summary in
                    BarChart.Bar(label: hour % 3 == 0 ? "\(hour)" : "", value: summary.ratePerMinute)
                }, threshold: threshold, showValues: false)
                    .frame(height: 110)
            }

            HStack {
                Label("Orange: under \(reminders.threshold) blinks a minute, the limit you set.", systemImage: "square.fill")
                    .labelStyle(LegendStyle(color: .orange))
                Spacer()
                Button("Show Data File") { NSWorkspace.shared.activateFileViewerSelecting([history.store.file]) }
                    .help("One line per minute, in a file any spreadsheet opens. No picture is ever stored.")
            }
            .font(.callout)
        }
        .padding(20)
        .frame(width: 600)
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

/// A plain bar chart: one bar per value (nil = nothing recorded), a dashed threshold line.
struct BarChart: View {

    struct Bar {
        let label: String
        let value: Double?
    }

    let bars: [Bar]
    let threshold: Double
    let showValues: Bool

    var body: some View {
        Canvas { context, size in
            let labelHeight: CGFloat = 16
            let valueHeight: CGFloat = showValues ? 16 : 0
            let plot = CGRect(x: 0, y: valueHeight, width: size.width, height: size.height - labelHeight - valueHeight)
            let top = max(threshold * 1.8, (bars.compactMap(\.value).max() ?? 0) * 1.1, 1)
            let slot = plot.width / CGFloat(max(bars.count, 1))
            let barWidth = min(slot * 0.62, 46)

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
                        context.draw(Text(String(format: "%.1f", value)).font(.caption.weight(.semibold)),
                                     at: CGPoint(x: centre, y: rect.minY - 9))
                    }
                } else {
                    // Nothing recorded: a faint mark, so the gap reads as "no data", not "zero".
                    let rect = CGRect(x: centre - barWidth / 2, y: plot.maxY - 2, width: barWidth, height: 2)
                    context.fill(Path(rect), with: .color(.secondary.opacity(0.25)))
                }
                if !bar.label.isEmpty {
                    context.draw(Text(bar.label).font(.caption).foregroundStyle(.secondary),
                                 at: CGPoint(x: centre, y: size.height - labelHeight / 2 + 1))
                }
            }
        }
    }
}
