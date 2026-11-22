import SwiftUI
import AppKit

/// Reading comfort: the colours and the system settings that people with tired eyes rely
/// on. They are the people this app is for.
public extension Color {

    /// Orange for TEXT. Plain orange on the light window background is about 1.9 to 1,
    /// where 4.5 to 1 is the usual minimum: the app's warnings were its least readable
    /// words. This one is darkened in light mode (about 5 to 1), and darker still when
    /// Increase Contrast is on. Bars, dots and symbols keep the plain orange.
    static let warningText = Color(nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: return .systemOrange
        case .accessibilityHighContrastDarkAqua: return NSColor(srgbRed: 1.0, green: 0.72, blue: 0.35, alpha: 1)
        case .accessibilityHighContrastAqua: return NSColor(srgbRed: 0.48, green: 0.21, blue: 0.0, alpha: 1)
        default: return NSColor(srgbRed: 0.62, green: 0.29, blue: 0.0, alpha: 1)
        }
    })

    /// Green under a white tick. White on the system green is about 2.2 to 1.
    static let doneGreen = Color(nsColor: NSColor(srgbRed: 0.12, green: 0.52, blue: 0.24, alpha: 1))
}

/// What macOS says in System Settings > Accessibility > Display, for the parts of the app
/// that are not SwiftUI views (the menu-bar item).
public enum Comfort {
    /// Reduce Motion: the menu-bar eye stops blinking back, about 15 times a minute at
    /// the edge of vision.
    public static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Lays chips out side by side and goes to a new line when they do not fit. A routine's
/// times simply disappeared when they were too many for one line, which a 12-hour clock
/// ("8:00 AM") makes likely.
public struct WrappingRow: Layout {
    private let spacing: CGFloat

    public init(spacing: CGFloat = 6) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.width, height: rows.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = place(subviews, width: bounds.width)
        for (subview, point) in zip(subviews, rows.points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    /// Where each subview goes, and the size of the whole.
    private func place(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + rowHeight)
    }
}
