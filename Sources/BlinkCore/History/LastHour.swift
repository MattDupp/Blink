import Foundation
import CoreGraphics

/// The last 60 minutes as a chart needs them: one rate per minute, by how long ago.
///
/// It is built from the minutes AND the present moment, each time it is drawn. (The first
/// version of the panel kept the moment it was created and never looked at the clock
/// again: its chart went on showing the hour before the app was launched.)
public struct LastHour: Equatable {

    /// Index 0 = the minute in progress, 59 = fifty-nine minutes ago. Nil: not watched.
    public private(set) var rates = [Double?](repeating: nil, count: 60)
    private let currentStart: Date

    /// `minutes`: finished minutes, oldest first. `current`: the minute being filled.
    public init(minutes: [MinuteRecord], current: MinuteRecord?, now: Date) {
        currentStart = MinuteRecord.minuteStart(of: now)
        // The finished minutes are in order of time: the last 60 are enough to look at.
        for record in minutes.suffix(60) + [current].compactMap({ $0 }) {
            let ago = Int((currentStart.timeIntervalSince(record.start) / 60).rounded())
            if rates.indices.contains(ago) { rates[ago] = record.ratePerMinute }
        }
    }

    public var isEmpty: Bool { rates.allSatisfy { $0 == nil } }

    public func rate(minutesAgo: Int) -> Double? {
        rates.indices.contains(minutesAgo) ? rates[minutesAgo] : nil
    }

    public func start(minutesAgo: Int) -> Date {
        currentStart.addingTimeInterval(-Double(minutesAgo) * 60)
    }

    /// Which minute a point of the chart belongs to (the newest is on the right).
    public static func minutesAgo(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return min(59, max(0, 59 - Int(x / (width / 60))))
    }
}
