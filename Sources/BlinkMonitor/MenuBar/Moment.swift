import SwiftUI

/// The moment a window describes: the present, read from the clock each time it is asked.
///
/// WHY A TYPE FOR "NOW". The windows used to hold a plain `var now = Date()`, so that the
/// screenshots could be given a fixed moment. But a view is created once and kept: that
/// date was the moment the app was LAUNCHED, for as long as it ran. The last-hour chart
/// drew the hour before launch and never a minute after it, "today" was still yesterday
/// after midnight, and no test saw it, because every test passed its own date.
/// A view now holds a `Moment`, which has no date in it unless a screenshot froze one.
struct Moment {
    /// Set only by the screenshots, which must not change from day to day.
    var frozen: Date?

    var now: Date { frozen ?? Date() }
}

/// Draws its content for the present moment - and again when the minute changes, even if
/// nothing else did (the camera is paused, nobody is in view).
struct AtPresent<Content: View>: View {
    let moment: Moment
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.everyMinute) { _ in
            content(moment.now)
        }
    }
}
