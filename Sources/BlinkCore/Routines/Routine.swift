import Foundation

/// A time on the clock, with no day and no time zone: "08:00".
///
/// A routine's times are what the wall clock shows where you are. They are kept as hour
/// and minute, never as a moment: 08:00 stays 08:00 after a flight or a change of
/// daylight saving.
public struct TimeOfDay: Codable, Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public static func < (left: TimeOfDay, right: TimeOfDay) -> Bool {
        (left.hour, left.minute) < (right.hour, right.minute)
    }

    /// "08:00": always two digits and 24 hours. This is how a time is written in the
    /// record file, so it must not follow the Mac's language (the screens use `Format.time`).
    public var text: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// When a routine asks for you. Three kinds, because eye care has all three:
/// something at fixed times, something a few times a week, something after a while at
/// the screen.
public enum RoutineSchedule: Codable, Equatable {
    /// At these times, every day (`weekdays` nil) or on the chosen days of the week
    /// (1 = Sunday ... 7 = Saturday, as `Calendar` counts them).
    case timesOfDay(times: [TimeOfDay], weekdays: Set<Int>?)
    /// This many times a week, on days you choose as you go.
    /// NOT PLANNED YET: `RoutineDay` gives it no slots. See "Where a new kind plugs in" there.
    case timesPerWeek(count: Int)
    /// Every so many minutes at the screen.
    /// NOT PLANNED YET either: it needs the time at the screen, which the clock does not know.
    case everyMinutesAtScreen(minutes: Int)
}

/// Something you decided to do regularly for your eyes, that the app reminds you of.
///
/// The app reminds; it does not prescribe. The times are the ones you, or your eye-care
/// professional, chose.
public struct Routine: Codable, Equatable, Identifiable {
    /// Stable and plain ("eye-drops"): it is written in the record file and in the
    /// settings, so it never changes, and holds no comma.
    public let id: String
    public var name: String
    /// An SF Symbol.
    public var symbol: String
    public var schedule: RoutineSchedule
    public var isOn: Bool
    /// When it was last switched on. A time that had already passed at that moment is not
    /// asked for: switching a routine on at 13:10 must not answer with a reminder for 13:00.
    public var onSince: Date?

    public init(id: String, name: String, symbol: String, schedule: RoutineSchedule, isOn: Bool = false,
                onSince: Date? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.schedule = schedule
        self.isOn = isOn
        self.onSince = onSince
    }

    /// The times of a `timesOfDay` routine, in order and without doubles (else empty).
    public var times: [TimeOfDay] {
        if case .timesOfDay(let times, _) = schedule { return Array(Set(times)).sorted() }
        return []
    }

    // MARK: The routines the app comes with

    /// Off until switched on. The three times are a starting point to edit, not advice.
    public static let eyeDrops = Routine(
        id: "eye-drops", name: "Eye drops", symbol: "drop",
        schedule: .timesOfDay(times: [TimeOfDay(hour: 8), TimeOfDay(hour: 13), TimeOfDay(hour: 17)], weekdays: nil))

    /// Every routine the app comes with. A new one is added here, and nowhere else.
    public static let builtIn: [Routine] = [.eyeDrops]

    /// The stored routines, plus any built-in one that is not among them yet: a routine
    /// added in a later version appears (switched off) for people who already have settings.
    public static func merged(stored: [Routine]) -> [Routine] {
        let known = Set(stored.map(\.id))
        return stored + builtIn.filter { !known.contains($0.id) }
    }
}
