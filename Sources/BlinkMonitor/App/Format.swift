import Foundation
import BlinkUI

/// How the app writes durations, times and days: once, so every window says them alike.
enum Format {
    /// Where a number is missing: one dash, the same everywhere (`RateReadout.none`).
    static let none = RateReadout.none

    /// "42 min", "2 h 5 min", "3 h".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        guard minutes >= 60 else { return "\(minutes) min" }
        // "5 h 10" is not an English duration, and "3 h 00" says nothing more than "3 h".
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// A rate with one decimal, written the way this Mac writes numbers ("13.2", "13,2").
    static func rate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// An hour of the day as this Mac writes times: "14:00", or "2:00 PM".
    static func hour(_ hour: Int, calendar: Calendar = .current) -> String {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 0)).map(time) ?? "\(hour):00"
    }

    /// The same, short, for an axis: "14", or "2 PM".
    static func hourLabel(_ hour: Int, calendar: Calendar = .current) -> String {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 0))
            .map { $0.formatted(.dateTime.hour()) } ?? "\(hour)"
    }

    /// "70%": a share as this Mac writes a percentage.
    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "two", "ten": a small count as a sentence says it; digits above ten.
    static func word(_ number: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(number) ? words[number] : number.formatted()
    }

    /// "1 minute", "3 minutes": a number with its noun, so that no sentence says "1 minutes".
    static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number.formatted()) \(noun)s"
    }

    /// "16:30".
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "18 Nov".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// A moment ahead, as short as it can be said without doubt: "09:00" within the next
    /// 24 hours, "Mon 09:00" further away.
    static func ahead(_ date: Date, from now: Date) -> String {
        date.timeIntervalSince(now) < 86_400 ? time(date) : "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time(date))"
    }

    /// When a pause ends: "16:30", or "tomorrow" for the pause that lasts until midnight.
    static func pauseEnd(_ date: Date, calendar: Calendar = .current) -> String {
        calendar.startOfDay(for: date) == date ? "tomorrow" : time(date)
    }
}
