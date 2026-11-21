import Foundation

/// A timed session of a routine: started at one moment, over at another.
///
/// It holds the END, not a count of seconds left. A countdown that is decremented stops
/// while the Mac sleeps and is wrong afterwards; an end compared with the clock is right
/// whenever it is asked.
public struct RoutineSession: Equatable {

    /// The routine's `id`.
    public let routine: String
    public let start: Date
    public let end: Date

    /// Nil when the routine has no timer.
    public init?(routine: Routine, start: Date) {
        guard let minutes = routine.sessionMinutes, minutes > 0 else { return nil }
        self.routine = routine.id
        self.start = start
        end = start.addingTimeInterval(Double(minutes) * 60)
    }

    public func isOver(at now: Date) -> Bool {
        now >= end
    }

    /// Seconds left, never below zero.
    public func remaining(at now: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(now))
    }

    /// From 0 at the start to 1 at the end.
    public func progress(at now: Date) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 1 }
        return min(max(now.timeIntervalSince(start) / length, 0), 1)
    }

    /// "7:05": minutes and seconds left.
    public func clock(at now: Date) -> String {
        let seconds = Int(remaining(at: now).rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
