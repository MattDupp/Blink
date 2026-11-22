import SwiftUI

/// The blink rate, as it is written everywhere in the app: a large number and its unit,
/// sitting on the same line.
///
/// ONE view on purpose. The first version wrote this layout twice (in the panel and in
/// the Live View window), with the unit on two lines aligned on its FIRST line: the
/// second line hung under the number, and the two copies could drift apart. Here the unit
/// is one line, aligned on the number's baseline - the line the digits stand on.
public struct RateReadout: View {

    private let rate: Double?
    private let tint: Color
    private let size: CGFloat

    /// `rate`: blinks a minute, nil when there is none to show (drawn as a quiet dash).
    public init(rate: Double?, tint: Color = .primary, size: CGFloat = 52) {
        self.rate = rate
        self.tint = tint
        self.size = size
    }

    /// What stands where a number is missing: a real dash. It was two hyphens, in six places.
    public static let none = "–"

    /// The rate as the app writes it everywhere: a whole number, or a dash.
    public static func text(_ rate: Double?) -> String {
        rate.map { String(format: "%.0f", $0) } ?? none
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(Self.text(rate))
                .font(.system(size: size, weight: rate == nil ? .light : .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(rate == nil ? Color.secondary.opacity(0.6) : tint)
                .contentTransition(.numericText())
            Text("blinks a minute")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rate == nil ? "No rate yet" : "\(Self.text(rate)) blinks a minute")
    }
}
