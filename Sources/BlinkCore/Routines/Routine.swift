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
    /// This many times a week: a count to reach, not appointments. It asks at `time` on
    /// the `weekdays` you prefer (1 = Sunday ... 7 = Saturday), and on other days when you
    /// are behind. `RoutineWeek` holds the rule.
    case timesPerWeek(count: Int, weekdays: Set<Int>, time: TimeOfDay)
    /// Every so many minutes AT THE SCREEN: minutes with somebody there, not minutes on
    /// the clock. `ScreenCount` holds the rule.
    case everyMinutesAtScreen(minutes: Int)

    /// The three kinds, without their details: what the editor's picker chooses between.
    public enum Kind: String, CaseIterable, Identifiable {
        case timesOfDay, timesPerWeek, atScreen
        public var id: String { rawValue }
    }

    public var kind: Kind {
        switch self {
        case .timesOfDay: return .timesOfDay
        case .timesPerWeek: return .timesPerWeek
        case .everyMinutesAtScreen: return .atScreen
        }
    }

    /// The minutes an "at the screen" routine can be set to. Under a quarter of an hour it
    /// would be a pest; over four hours it would hardly ever come.
    public static let screenMinutes = 15...240

    /// What a routine starts from when it is given this kind. A starting point to edit.
    public static func starting(_ kind: Kind) -> RoutineSchedule {
        switch kind {
        case .timesOfDay: return .timesOfDay(times: [TimeOfDay(hour: 9)], weekdays: nil)
        case .timesPerWeek: return .timesPerWeek(count: 3, weekdays: [2, 4, 6], time: TimeOfDay(hour: 17))
        case .atScreen: return .everyMinutesAtScreen(minutes: 60)
        }
    }
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
    /// Set for a routine that takes a while and is timed: the length of its timer, in
    /// minutes. Nil: no timer. The length is the user's own setting, never advice.
    public var sessionMinutes: Int?
    /// Its reminder comes with the Mac's notification sound. Nil or false: in silence,
    /// which is how every routine starts. (Optional, so that routines stored before this
    /// existed are still read.)
    public var soundOn: Bool?
    /// A built-in routine the user asked not to see in Settings any more. It can be
    /// brought back from "Add a Routine". Nil or false: shown.
    public var hidden: Bool?

    public var playsSound: Bool { soundOn ?? false }
    public var isHidden: Bool { hidden ?? false }

    public init(id: String, name: String, symbol: String, schedule: RoutineSchedule, isOn: Bool = false,
                onSince: Date? = nil, sessionMinutes: Int? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.schedule = schedule
        self.isOn = isOn
        self.onSince = onSince
        self.sessionMinutes = sessionMinutes
    }

    /// For an "at the screen" routine: every how many minutes. Nil for the other kinds.
    public var screenMinutes: Int? {
        if case .everyMinutesAtScreen(let minutes) = schedule { return max(minutes, 1) }
        return nil
    }

    // MARK: What the user types

    /// The longest name kept. A name is shown in a banner, in the panel and in the menu
    /// bar's tooltip: it has to fit there.
    public static let nameLimit = 40
    /// The symbols a routine of your own can be given (SF Symbols).
    public static let symbols = ["bell", "drop", "eye", "cup.and.saucer", "figure.walk", "pills", "leaf", "sun.max",
                                 "moon", "heart", "clock", "star"]

    /// A typed name, made safe to keep: one line, no control characters, at most
    /// `nameLimit` characters. A space at the end is kept, so that the next word can be
    /// typed; `title` is the name as it is shown.
    ///
    /// The name is never written to the record file: a line of `routines.csv` names its
    /// routine by `id`. So nothing typed here can break that file, and a routine can be
    /// renamed without losing a line of its record.
    public static func typedName(_ text: String) -> String {
        let oneLine = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        }
        return String(String(oneLine).drop { $0 == " " }.prefix(nameLimit))
    }

    /// The name as it is shown: trimmed, and never empty.
    public var title: String {
        let shown = Self.typedName(name).trimmingCharacters(in: .whitespaces)
        return shown.isEmpty ? "Routine" : shown
    }

    /// One of the routines the app comes with: it can be switched off, not deleted.
    public var isBuiltIn: Bool {
        Self.builtIn.contains { $0.id == id }
    }

    /// A routine of your own, from a starting point. Its `id` is drawn at random and
    /// never changes: the record knows the routine by it, whatever it is called later.
    public static func made(from template: RoutineTemplate, now: Date,
                            id: String = "user-" + UUID().uuidString.prefix(8).lowercased()) -> Routine {
        Routine(id: id, name: template.name, symbol: template.symbol, schedule: template.schedule, isOn: true, onSince: now)
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

    /// Off until switched on. Three times a week, asked on Monday, Wednesday and Friday at
    /// 18:00 (an hour after the last eye drops: both started at 17:00, and came as two
    /// banners five minutes apart), with a ten-minute timer: all four are a starting point to edit, not advice.
    /// The timer's length is to be set to what the mask's own instructions say.
    public static let heatedMask = Routine(
        id: "heated-mask", name: "Heated eye mask", symbol: "eye",
        schedule: .timesPerWeek(count: 3, weekdays: [2, 4, 6], time: TimeOfDay(hour: 18)), sessionMinutes: 10)

    /// Every routine the app comes with. A new one is added here, and nowhere else.
    public static let builtIn: [Routine] = [.eyeDrops, .heatedMask]

    /// The stored routines, plus any built-in one that is not among them yet: a routine
    /// added in a later version appears (switched off) for people who already have settings.
    public static func merged(stored: [Routine]) -> [Routine] {
        let known = Set(stored.map(\.id))
        return stored + builtIn.filter { !known.contains($0.id) }
    }
}

/// A starting point for a routine of your own. Each is described by what it does, never
/// by what it is good for: the app reminds, it gives no advice.
public struct RoutineTemplate: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let symbol: String
    public let schedule: RoutineSchedule
    /// What it does, for the list it is picked from.
    public let summary: String

    public static let all: [RoutineTemplate] = [
        RoutineTemplate(id: "water", name: "Drink water", symbol: "cup.and.saucer",
                        schedule: .everyMinutesAtScreen(minutes: 60), summary: "Drink water: every 60 minutes at the screen"),
        RoutineTemplate(id: "stand", name: "Stand up", symbol: "figure.walk",
                        schedule: .everyMinutesAtScreen(minutes: 45), summary: "Stand up: every 45 minutes at the screen"),
        RoutineTemplate(id: "times", name: "My routine", symbol: "bell",
                        schedule: RoutineSchedule.starting(.timesOfDay), summary: "A routine at set times of day"),
        RoutineTemplate(id: "week", name: "My routine", symbol: "bell",
                        schedule: RoutineSchedule.starting(.timesPerWeek), summary: "A routine a few times a week"),
    ]
}
