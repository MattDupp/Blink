import SwiftUI
import AppKit

/// ONE RULE FOR EVERY WINDOW: none is taller than the screen can show.
///
/// The windows have a fixed size, the size of their content. Settings > Routines was
/// about 890 points tall, History 770, the panel with every routine open 840; a 13-inch
/// MacBook Air shows about 840 with the Dock, an older one 776. What did not fit was cut
/// off below the screen, buttons included, and nothing scrolled.
///
/// So the part of a window that can grow is wrapped in this. While it fits, nothing
/// changes: the window is as tall as its content. When it would not fit, that part stops
/// at the room the screen has and scrolls; what is outside it (a tab bar, a row of
/// buttons) stays where it is.
public struct ScrollsWhenTall<Content: View>: View {
    @Environment(\.screenRoom) private var room
    private let reserved: CGFloat
    private let content: Content

    /// `reserved`: the height of what stays put around this part: the title bar, a tab
    /// bar, a row of buttons, the paddings.
    public init(reserved: CGFloat, @ViewBuilder content: () -> Content) {
        self.reserved = reserved
        self.content = content()
    }

    public var body: some View {
        CappedHeight(limit: max(240, (room ?? ScreenRoom.height) - reserved)) {
            ScrollView(.vertical) { content }
        }
    }
}

public enum ScreenRoom {
    /// The height a window may take on the screen in use: what is left by the menu bar
    /// and the Dock, less a small margin.
    public static var height: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 16
    }
}

/// As tall as its content wants to be, up to a limit.
private struct CappedHeight: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        // A scroll view asked for its ideal height answers with the height of what it holds.
        let ideal = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct ScreenRoomKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

public extension EnvironmentValues {
    /// The room a window may take, when it is not this Mac's screen that decides: the
    /// screenshots state it (whole by default, or a small screen to look at the scrolling).
    var screenRoom: CGFloat? {
        get { self[ScreenRoomKey.self] }
        set { self[ScreenRoomKey.self] = newValue }
    }
}
