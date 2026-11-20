import Foundation

/// How long a pause lasts.
public enum PauseDuration: CaseIterable, Equatable {
    case fifteenMinutes
    case oneHour
    case untilTomorrow
    /// Until you choose Resume.
    case untilResumed

    /// The moment the pause ends by itself; nil when it does not.
    public func end(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
        case .oneHour: return now.addingTimeInterval(3600)
        case .untilTomorrow:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .untilResumed: return nil
        }
    }
}

/// Whether the camera is paused, and until when.
///
/// The first version had a pause with no end, and a pause you forget is a monitor that is
/// silently off. A pause now says when it ends, and ends by itself.
public enum PauseState: Equatable {
    case running
    /// `until` nil: until resumed by hand.
    case paused(until: Date?)

    public init(_ duration: PauseDuration, from now: Date, calendar: Calendar = .current) {
        self = .paused(until: duration.end(from: now, calendar: calendar))
    }

    /// The state once time has passed: a timed pause whose end is reached is over.
    public func resolved(at now: Date) -> PauseState {
        if case .paused(let until?) = self, now >= until { return .running }
        return self
    }

    public func isPaused(at now: Date) -> Bool {
        resolved(at: now) != .running
    }

    /// When the pause ends by itself, if it does.
    public var end: Date? {
        if case .paused(let until) = self { return until }
        return nil
    }
}
