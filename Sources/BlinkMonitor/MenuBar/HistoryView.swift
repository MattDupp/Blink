import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

/// What the History window remembers while it is open.
@MainActor
final class HistoryState: ObservableObject {
    /// The day shown hour by hour (the start of that day); nil = today.
    @Published var selectedDay: Date?
    /// The bar or cell under the pointer: its value is written under its chart.
    @Published var hoveredDay: Int?
    @Published var hoveredHour: Int?
    @Published var hoveredCell: HeatMap.Cell?
    /// The seven days shown: 0 = the last seven, 1 = the seven before (`HistoryWeek`).
    @Published var week = 0 { didSet { if week != oldValue { selectedDay = nil } } }
    @Published var hoveredWeek: Int?
}

/// The history window: your last seven days, any of them hour by hour, and the week as
/// one picture. With more than a week on file, the earlier weeks too: two arrows go from
/// week to week, and a row of the last twelve weeks shows them together.
///
/// The question it answers is "WHEN do I blink too little?". One figure for a day hides it;
/// the hours show it (typically: the stretch of deep concentration in the afternoon).
struct HistoryView: View {
    @ObservedObject var history: HistoryController
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: HistoryState
    /// The moment the window describes: the present, except in the screenshots.
    var moment = Moment()
    /// "Export…": copies the history and the routine log where the user chooses.
    var export: () -> Void = {}

    private var limit: Double { Double(preferences.limit) }

    var body: some View {
        AtPresent(moment: moment) { now in window(now: now) }
    }

    private func window(now: Date) -> some View {
        let calendar = Calendar.current
        // The seven days shown. Week 0 is today and the six days before, as it always was.
        let all = history.allRecords()
        let shown = HistoryWeeks.week(state.week, now: now, calendar: calendar)
        let weekRecords = shown.records(in: all)
        let days = shown.days.map { (day: $0, summary: DaySummary(records: weekRecords.on($0, calendar: calendar), threshold: limit)) }
        let today = calendar.startOfDay(for: now)
        // In an earlier week no day is "today": its last day is the one opened.
        let selected = state.selectedDay.flatMap { shown.contains($0) ? $0 : nil } ?? (shown.isInProgress ? today : shown.lastDay)
        // The row of weeks appears once something is on file before these seven days.
        let weeks = HistoryWeeks.weeks(now: now, calendar: calendar)
        let hasEarlierWeeks = HistoryWeeks.hasEarlier(than: HistoryWeeks.week(0, now: now, calendar: calendar), records: all,
                                                      now: now, calendar: calendar)
        let week = DaySummary(records: weekRecords, threshold: limit)
        // Both hour charts show the hours this week used, not the whole clock.
        let hours = Insights.hoursUsed(records: weekRecords)
        let hourly = history.hours(of: selected, threshold: limit)

        // 44: the title bar. On a screen too low for the whole window, it scrolls.
        return ScrollsWhenTall(reserved: 44) { VStack(alignment: .leading, spacing: 18) {
            if weekRecords.isEmpty && !hasEarlierWeeks {
                NothingYet()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionTitle(HistoryWords.title(of: shown))
                        Spacer()
                        if hasEarlierWeeks {
                            WeekStepper(week: state.week,
                                        hasEarlier: HistoryWeeks.hasEarlier(than: shown, records: all, now: now, calendar: calendar)) {
                                state.week = $0
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        StatTile(value: Format.duration(week.observedSeconds), caption: "at the screen")
                        StatTile(value: week.ratePerMinute.map(Format.rate) ?? Format.none, caption: "blinks a minute")
                        StatTile(value: week.lowShare.map { "\(Int(((1 - $0) * 100).rounded()))%" } ?? Format.none,
                                 caption: "above your limit")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    BarChart(bars: days.map { day in
                        BarChart.Bar(label: day.day.formatted(.dateTime.weekday(.abbreviated)), value: day.summary.ratePerMinute)
                    }, threshold: limit, showValues: true,
                             selected: days.firstIndex { $0.day == selected }, hovered: state.hoveredDay,
                             onHover: { state.hoveredDay = $0 }) { state.selectedDay = days[$0].day }
                        .frame(height: 140)
                        .accessibilityLabel("Blink rate for each of the last seven days")
                        .accessibilityValue(days.map { "\($0.day.formatted(.dateTime.weekday(.wide))) \($0.summary.ratePerMinute.map(Format.rate) ?? "nothing")" }
                            .joined(separator: ", "))
                    ChartCaption(state.hoveredDay.flatMap { days.indices.contains($0) ? days[$0] : nil }.map { day in
                        Self.said(day.day.formatted(.dateTime.weekday(.wide)), day.summary)
                    } ?? (weekRecords.isEmpty ? HistoryWords.emptyWeek : "Click a day to see its hours."))
                }

                if !weekRecords.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionTitle(selected == today ? "Today, hour by hour" : "\(selected.formatted(.dateTime.weekday(.wide).day().month(.wide))), hour by hour")
                        Spacer()
                        DayStepper(days: days.map(\.day), selected: selected) { state.selectedDay = $0 }
                    }
                    BarChart(bars: hours.map { hour in
                        BarChart.Bar(label: Self.labelled(hour, in: hours) ? Format.hourLabel(hour) : "", value: hourly[hour].ratePerMinute)
                    }, threshold: limit, showValues: false, hovered: state.hoveredHour, onHover: { state.hoveredHour = $0 })
                        .frame(height: 100)
                        .accessibilityLabel("Blink rate for each hour of the day shown")
                        .accessibilityValue(hours.compactMap { hour in hourly[hour].ratePerMinute.map { "\(Format.hour(hour)) \(Format.rate($0))" } }
                            .joined(separator: ", "))
                    ChartCaption(state.hoveredHour.flatMap { index in hours.dropFirst(index).first }.map { hour in
                        Self.said(Format.hour(hour), hourly[hour])
                    } ?? " ")
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("The week, by hour of the day")
                    let rates = Insights.heatMap(records: weekRecords, days: days.map(\.day))
                    HeatMap(days: days.map(\.day), rates: rates, hours: hours,
                            limit: limit, selected: selected, hovered: state.hoveredCell,
                            onHover: { state.hoveredCell = $0 }) { state.selectedDay = $0 }
                    ChartCaption(state.hoveredCell.flatMap { cell -> String? in
                        guard days.indices.contains(cell.row) else { return nil }
                        let name = "\(days[cell.row].day.formatted(.dateTime.weekday(.abbreviated))) \(Format.hour(cell.hour))"
                        return rates[cell.row][cell.hour].map { "\(name): \(Format.rate($0)) blinks a minute" } ?? "\(name): not counted"
                    } ?? "Click a row to see that day. A dot marks an hour under your limit.")
                }

                }

                if hasEarlierWeeks {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(HistoryWords.weeksTitle)
                        let summaries = HistoryWeeks.summaries(of: weeks, records: all, threshold: limit)
                        BarChart(bars: zip(weeks, summaries).map { week, summary in
                            BarChart.Bar(label: Format.day(week.start), value: summary.ratePerMinute)
                        }, threshold: limit, showValues: true,
                                 selected: weeks.firstIndex { $0.index == state.week }, hovered: state.hoveredWeek,
                                 onHover: { state.hoveredWeek = $0 }, onSelect: { state.week = weeks[$0].index }, namesLimit: false)
                            .frame(height: 110)
                            .accessibilityLabel("Blink rate for each of the last twelve weeks")
                            .accessibilityValue(zip(weeks, summaries).map { HistoryWords.said($0, $1) }.joined(separator: ", "))
                        ChartCaption(state.hoveredWeek.flatMap { weeks.indices.contains($0) ? $0 : nil }.map { HistoryWords.said(weeks[$0], summaries[$0]) }
                                     ?? HistoryWords.weeksHint)
                    }
                }

                let findings = self.findings(days: days, weekRecords: weekRecords, week: week, isLastSeven: shown.isInProgress)
                if !findings.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        SectionTitle("What stands out")
                        ForEach(findings, id: \.text) { finding in
                            Label(finding.text, systemImage: finding.symbol)
                                .foregroundStyle(finding.tint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textStyle(.callout)
                }

                HStack {
                    Label("Orange: under \(preferences.limit) blinks a minute, your limit.", systemImage: "square.fill")
                        .labelStyle(LegendStyle(color: .orange))
                    Spacer()
                    Button("Export…") { export() }
                        .help("Copies your history and your routine log to a folder you choose: one line per minute, in files any spreadsheet opens. No picture is ever stored.")
                }
                .textStyle(.callout)
            }
        }
        .padding(20)
        }
        .windowWidth(620)
    }

    /// "Tuesday: 11.4 blinks a minute, 5 h 2 min at the screen."
    static func said(_ name: String, _ summary: DaySummary) -> String {
        guard let rate = summary.ratePerMinute else { return "\(name): not counted" }
        return "\(name): \(Format.rate(rate)) blinks a minute, \(Format.duration(summary.observedSeconds)) at the screen"
    }

    /// Every third hour is named under the hour chart, counted from the first one drawn.
    static func labelled(_ hour: Int, in hours: ClosedRange<Int>) -> Bool {
        hours.count <= 8 || (hour - hours.lowerBound) % 3 == 0
    }

    /// The few sentences the numbers support, and that the charts above do not already
    /// say: the hours when your rate is lowest, and a drift from your usual rate. (The
    /// highest and lowest day repeated the chart, "matches your usual rate" said nothing,
    /// and the studies line never changed: it is in Settings.)
    private func findings(days: [(day: Date, summary: DaySummary)], weekRecords: [MinuteRecord],
                          week: DaySummary, isLastSeven: Bool) -> [(symbol: String, text: String, tint: Color)] {
        var findings: [(String, String, Color)] = []

        // The two lowest hours, in the order of the day.
        let lowest = Insights.lowestHours(records: weekRecords).sorted { $0.hour < $1.hour }
        if lowest.count == 2 {
            findings.append(("clock", "Your rate is lowest around \(Format.hour(lowest[0].hour)) and \(Format.hour(lowest[1].hour)) "
                             + "(\(Format.rate(lowest[0].rate)) and \(Format.rate(lowest[1].rate)) a minute): the hours where a break counts most.",
                             .primary))
        }

        // "This week" is said of the last seven days only.
        if isLastSeven, preferences.automaticLimit, let reference = preferences.reference,
           let drift = Baseline.drift(reference: reference, recent: weekRecords) {
            let measured = "your usual rate of \(Format.rate(reference.rate)) a minute, measured on \(Format.day(reference.measuredOn))"
            if drift >= Baseline.driftWorthSaying {
                findings.append(("arrow.down.right", String(format: "This week you blink %.0f%% less than %@. The limit has not moved.", drift * 100, measured), .warningText))
            } else if drift <= -Baseline.driftWorthSaying {
                findings.append(("arrow.up.right", String(format: "This week you blink %.0f%% more than %@.", -drift * 100, measured), .primary))
            }
        }
        return findings
    }
}

/// The line under a chart: the value under the pointer, or what a click does. One line
/// high whatever it says, so the window does not move under the pointer.
private struct ChartCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .textStyle(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a new install shows instead of seven empty charts.
private struct NothingYet: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("Nothing recorded yet")
                .textStyle(.title2, weight: .semibold)
            Text("One line is kept for every minute counted. After a few minutes this window shows your days, each of them hour by hour, and the hours when your rate drops.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            // Where to look meanwhile: an empty window sent people nowhere.
            Text("Meanwhile, the menu-bar panel shows your rate now and the last hour, minute by minute: click the eye in the menu bar.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// The words of the weeks: which seven days are shown, and the row of twelve.
enum HistoryWords {
    /// "Last 7 days", or the two dates an earlier week runs between: "7 Nov to 13 Nov".
    static func title(of week: HistoryWeek) -> String {
        week.isInProgress ? "Last 7 days" : span(week)
    }

    static func span(_ week: HistoryWeek) -> String {
        "\(Format.day(week.start)) to \(Format.day(week.lastDay))"
    }

    static let weeksTitle = "The last 12 weeks"
    static let weeksHint = "Click a week to see its days. Each bar is seven days; the last one ends today."
    static let emptyWeek = "Nothing was counted in these seven days."

    /// "7 Nov to 13 Nov: 11.4 blinks a minute, 30 h 5 min at the screen".
    static func said(_ week: HistoryWeek, _ summary: DaySummary) -> String {
        HistoryView.said(week.isInProgress ? "Last 7 days" : span(week), summary)
    }
}

/// The two arrows that move the window from week to week. Week 0 is the latest.
private struct WeekStepper: View {
    let week: Int
    let hasEarlier: Bool
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { select(week + 1) } label: { Image(systemName: "chevron.left") }
                .disabled(!hasEarlier)
                .help(hasEarlier ? "The seven days before" : "Nothing is recorded before these days")
                .accessibilityLabel("Earlier week")
            Button { select(week - 1) } label: { Image(systemName: "chevron.right") }
                .disabled(week <= 0)
                .help(week > 0 ? "The seven days after" : "")
                .accessibilityLabel("Later week")
        }
        .smallControl()
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
        .smallControl()
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
/// side of the limit that hour was, its strength how far from it, and a dot marks the hours
/// under the limit, for eyes that do not tell the two colours apart. A click on a row
/// shows that day hour by hour.
struct HeatMap: View {

    /// One cell: a row (a day) and an hour of the day.
    struct Cell: Equatable {
        var row: Int
        var hour: Int
    }

    let days: [Date]
    /// `[day][hour]`, nil where too little was counted.
    let rates: [[Double?]]
    /// The hours drawn.
    var hours: ClosedRange<Int> = 0...23
    let limit: Double
    let selected: Date
    var hovered: Cell?
    var onHover: (Cell?) -> Void = { _ in }
    var onSelect: (Date) -> Void = { _ in }

    private let rowHeight: CGFloat = 17
    private let labelWidth: CGFloat = 38

    var body: some View {
        Canvas { context, size in
            let cell = (size.width - labelWidth) / CGFloat(hours.count)
            for (row, day) in days.enumerated() {
                let y = CGFloat(row) * rowHeight
                let label = Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption.weight(day == selected ? .bold : .regular))
                    .foregroundStyle(day == selected ? Color.primary : Color.secondary)
                context.draw(label, at: CGPoint(x: 0, y: y + rowHeight / 2), anchor: .leading)

                for (column, hour) in hours.enumerated() {
                    let rect = CGRect(x: labelWidth + CGFloat(column) * cell + 1, y: y + 1, width: cell - 2, height: rowHeight - 2)
                    let rate = rates[row][hour]
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(colour(rate)))
                    if let rate, Insights.isUnder(rate, limit: limit) {
                        let dot = CGRect(x: rect.midX - 1.5, y: rect.midY - 1.5, width: 3, height: 3)
                        context.fill(Path(ellipseIn: dot), with: .color(.primary.opacity(0.75)))
                    }
                    if hovered == Cell(row: row, hour: hour) {
                        context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.primary.opacity(0.6)), lineWidth: 1.5)
                    }
                }
            }
            for (column, hour) in hours.enumerated() where HistoryView.labelled(hour, in: hours) {
                context.draw(Text(Format.hourLabel(hour)).font(.caption).foregroundStyle(.secondary),
                             at: CGPoint(x: labelWidth + (CGFloat(column) + 0.5) * cell, y: CGFloat(days.count) * rowHeight + 8))
            }
        }
        .frame(height: CGFloat(days.count) * rowHeight + 16)
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        let row = Int(point.y / rowHeight)
                        if days.indices.contains(row) { onSelect(days[row]) }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): onHover(cell(at: point, width: geometry.size.width))
                        case .ended: onHover(nil)
                        }
                    }
            }
        }
        .accessibilityLabel("Blink rate for every hour of the last seven days")
        .accessibilityValue(spoken)
    }

    /// The cell under a point, nil over the day names or under the last row.
    private func cell(at point: CGPoint, width: CGFloat) -> Cell? {
        let row = Int(point.y / rowHeight)
        let column = Int((point.x - labelWidth) / ((width - labelWidth) / CGFloat(hours.count)))
        guard point.x >= labelWidth, days.indices.contains(row), column >= 0, column < hours.count else { return nil }
        return Cell(row: row, hour: hours.lowerBound + column)
    }

    /// The picture in words: how many of the hours counted were under the limit.
    private var spoken: String {
        let counted = rates.flatMap { $0 }.compactMap { $0 }
        let under = counted.filter { Insights.isUnder($0, limit: limit) }.count
        return "\(under) of \(counted.count) hours under your limit"
    }

    private func colour(_ rate: Double?) -> Color {
        guard let rate else { return .primary.opacity(0.05) }       // not counted
        let distance = min(1, abs(rate - limit) / max(limit, 1) * 2)
        return (Insights.isUnder(rate, limit: limit) ? Color.orange : Color.green).opacity(0.35 + 0.65 * distance)
    }
}

/// A plain bar chart: one bar per value (nil = nothing recorded), a dashed threshold line.
/// With `onSelect`, a click on a bar's column chooses it, and `selected` is drawn as chosen.
struct BarChart: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour

    struct Bar {
        let label: String
        let value: Double?
    }

    let bars: [Bar]
    let threshold: Double
    let showValues: Bool
    var selected: Int?
    /// The bar under the pointer, and the word that it changed.
    var hovered: Int?
    var onHover: ((Int?) -> Void)?
    var onSelect: ((Int) -> Void)?
    /// Off for the row of weeks: twelve bars leave the name no room beside the last
    /// value, and the charts above have already named the line.
    var namesLimit = true

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

            if let hovered, hovered != selected, bars.indices.contains(hovered) {
                let column = CGRect(x: CGFloat(hovered) * slot + 3, y: 0, width: slot - 6, height: size.height)
                context.fill(Path(roundedRect: column, cornerRadius: 6), with: .color(.primary.opacity(0.04)))
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
                    let under = Insights.isUnder(value, limit: threshold)
                    if withoutColour && under {
                        // "Differentiate without colour": a bar under the limit is hollow.
                        context.stroke(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: min(4, barWidth / 3)),
                                       with: .color(.orange), lineWidth: 2)
                    } else {
                        context.fill(Path(roundedRect: rect, cornerRadius: min(4, barWidth / 3)), with: .color(under ? .orange : .green))
                    }
                    if showValues {
                        // Above the bar - or above the limit line, when that line would
                        // otherwise run through the figures.
                        let crossed = lineY < rect.minY && lineY > rect.minY - 18
                        context.draw(Text(Format.rate(value)).font(.caption.weight(.semibold)),
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

            // The dashed line says what it is, at its right end.
            guard namesLimit else { return }
            let name = context.resolve(Text("limit \(Int(threshold))").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary))
            let measured = name.measure(in: size)
            let plate = CGRect(x: size.width - measured.width - 6, y: lineY - measured.height - 3, width: measured.width + 4, height: measured.height + 1)
            context.fill(Path(roundedRect: plate, cornerRadius: 3), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
            context.draw(name, at: CGPoint(x: plate.midX, y: plate.midY), anchor: .center)
        }
        .overlay {
            GeometryReader { geometry in
                let slot = geometry.size.width / CGFloat(max(bars.count, 1))
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        let index = Int(point.x / slot)
                        if bars.indices.contains(index) { onSelect?(index) }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let index = Int(point.x / slot)
                            onHover?(bars.indices.contains(index) ? index : nil)
                        case .ended: onHover?(nil)
                        }
                    }
            }
        }
    }
}
