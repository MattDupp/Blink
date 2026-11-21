import SwiftUI
import AppKit
import BlinkCore

/// What studies report, as one picture: a bar per situation on a scale of blinks a minute,
/// with the user's own rate and limit marked on it.
///
/// WHY A STRIP AND NOT A BAND BEHIND THE CHARTS. The range for screen work is wide
/// (`PublishedRates.atScreen`): drawn behind the bars of the History window it would cover
/// about four fifths of each chart and say nothing. Three bars side by side say what the studies say: the rate
/// depends on what you are doing, and screen work sits lowest.
///
/// GREY ON PURPOSE. Green and orange belong to the user's own limit. A range from studies
/// is neither good nor bad, so nothing here takes a colour, wherever the marker falls.
struct StudyRangesStrip: View {

    /// A rate to mark on the scale, with the few words that name it.
    struct Marker: Equatable {
        let label: String
        let rate: Double
    }

    /// The user's own rate: a solid line, named above the bars.
    var yours: Marker?
    /// The limit in force: a dashed line like the one in the charts, named under the scale.
    var limit: Marker?

    private let labelWidth: CGFloat = 158
    private let spanWidth: CGFloat = 104
    private let rowHeight: CGFloat = 22
    private let barHeight: CGFloat = 12
    /// Room above the bars for the user's marker, and under them for the scale and the limit.
    private let topRoom: CGFloat = 18
    private let scaleRoom: CGFloat = 16
    private let bottomRoom: CGFloat = 15

    var body: some View {
        let ranges = PublishedRates.ranges
        let top = PublishedRates.scaleTop
        Canvas { context, size in
            // One row per range, and a last one for the two rates the experiment tested.
            let plot = CGRect(x: labelWidth, y: topRoom, width: max(size.width - labelWidth - spanWidth, 40),
                              height: CGFloat(ranges.count + 1) * rowHeight)
            func x(_ rate: Double) -> CGFloat {
                plot.minX + CGFloat(min(max(rate, 0), top) / top) * plot.width
            }

            // The scale: a faint line every five blinks, numbered under the bars.
            for tick in stride(from: 0.0, through: top, by: 5) {
                var line = Path()
                line.move(to: CGPoint(x: x(tick), y: plot.minY))
                line.addLine(to: CGPoint(x: x(tick), y: plot.maxY))
                context.stroke(line, with: .color(.primary.opacity(0.08)), lineWidth: 1)
                context.draw(Text(StudyRange.written(tick)).font(.caption2).foregroundStyle(.tertiary),
                             at: CGPoint(x: x(tick), y: plot.maxY + scaleRoom / 2 + 1))
            }

            for (row, range) in ranges.enumerated() {
                let middle = plot.minY + (CGFloat(row) + 0.5) * rowHeight
                // The first row is the one that compares like with like: the app only
                // watches someone at a screen. It is drawn stronger.
                let first = row == 0
                context.draw(Text(range.situationName).font(.caption).foregroundStyle(first ? Color.primary : Color.secondary),
                             at: CGPoint(x: 0, y: middle), anchor: .leading)
                let bar = CGRect(x: x(range.lower), y: middle - barHeight / 2,
                                 width: x(range.upper) - x(range.lower), height: barHeight)
                context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(.primary.opacity(first ? 0.36 : 0.15)))
                context.draw(Text(range.span).font(.caption).monospacedDigit()
                                .foregroundStyle(first ? Color.primary : Color.secondary),
                             at: CGPoint(x: plot.maxX + 10, y: middle), anchor: .leading)
            }

            // The experiment is two points, not a range: nothing is known between them, so
            // nothing is drawn between them. Hollow where the eyes fared worse, full where
            // they fared as well as at the person's own rate.
            let experiment = PublishedRates.experiment
            let last = plot.minY + (CGFloat(ranges.count) + 0.5) * rowHeight
            context.draw(Text(experiment.rowName).font(.caption).foregroundStyle(Color.primary),
                         at: CGPoint(x: 0, y: last), anchor: .leading)
            let worse = CGRect(x: x(experiment.worseAt) - 5, y: last - 5, width: 10, height: 10)
            context.stroke(Path(ellipseIn: worse.insetBy(dx: 0.75, dy: 0.75)), with: .color(.primary), lineWidth: 1.5)
            let fine = CGRect(x: x(experiment.fineAt) - 5, y: last - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: fine), with: .color(.primary))
            context.draw(Text(experiment.span).font(.caption).monospacedDigit().foregroundStyle(Color.primary),
                         at: CGPoint(x: plot.maxX + 10, y: last), anchor: .leading)

            if let limit {
                var line = Path()
                // It stops at the bars: carried on to its name, it ran through the numbers
                // of the scale whenever the limit was a multiple of five.
                line.move(to: CGPoint(x: x(limit.rate), y: plot.minY))
                line.addLine(to: CGPoint(x: x(limit.rate), y: plot.maxY + 2))
                context.stroke(line, with: .color(.secondary.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Self.name(limit.label, at: x(limit.rate), y: plot.maxY + scaleRoom + bottomRoom / 2, colour: .secondary,
                          within: size.width, in: &context)
            }
            if let yours {
                var line = Path()
                line.move(to: CGPoint(x: x(yours.rate), y: plot.minY - 3))
                line.addLine(to: CGPoint(x: x(yours.rate), y: plot.maxY))
                context.stroke(line, with: .color(.primary), lineWidth: 1.5)
                let dot = CGRect(x: x(yours.rate) - 3, y: plot.minY - 6, width: 6, height: 6)
                context.fill(Path(ellipseIn: dot), with: .color(.primary))
                Self.name(yours.label, at: x(yours.rate), y: topRoom / 2 - 3, colour: .primary, weight: .semibold,
                          within: size.width, in: &context)
            }
        }
        .frame(height: topRoom + CGFloat(ranges.count + 1) * rowHeight + scaleRoom + bottomRoom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// Writes a marker's name centred on its line, pushed back inside the picture when the
    /// line is near an edge.
    private static func name(_ label: String, at x: CGFloat, y: CGFloat, colour: Color, weight: Font.Weight = .regular,
                             within width: CGFloat, in context: inout GraphicsContext) {
        let text = context.resolve(Text(label).font(.caption.weight(weight)).monospacedDigit().foregroundStyle(colour))
        let half = text.measure(in: CGSize(width: width, height: 40)).width / 2
        context.draw(text, at: CGPoint(x: min(max(x, half), width - half), y: y))
    }

    /// The picture in words, for VoiceOver.
    private var spoken: String {
        var parts = PublishedRates.ranges.map { "\($0.situationName): \($0.span) blinks a minute in studies" }
        parts.append("\(PublishedRates.experiment.rowName), in one experiment: \(PublishedRates.experiment.span)")
        if let yours { parts.append("\(yours.label) a minute") }
        if let limit { parts.append("\(limit.label) a minute") }
        return parts.joined(separator: ". ")
    }
}

/// The strip with its words under it: what the Settings window shows next to the limit.
struct StudyRangesSection: View {
    var yours: StudyRangesStrip.Marker?
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudyRangesStrip(yours: yours, limit: StudyRangesStrip.Marker(label: "limit \(limit)", rate: Double(limit)))
            Text(PublishedRates.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

/// The papers behind what the app says, each with what it found and a button that opens it.
struct SourcesList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PublishedRates.sources) { source in
                if source.id != PublishedRates.sources.first?.id { Divider() }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).fontWeight(.semibold)
                        Text("\(source.journal), \(source.readAs)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(source.finding)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Open") { NSWorkspace.shared.open(source.link) }
                        .help(source.title)
                        .accessibilityLabel("Open \(source.name) in the browser")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }
}
