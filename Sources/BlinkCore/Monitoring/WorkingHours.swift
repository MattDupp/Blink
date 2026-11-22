import Foundation

/// "Quiet outside working hours": the hours of the week in which banners may show.
///
/// Two times of day and the days of the week. Inside them the app behaves as always;
/// outside, `BannerGate` is quiet: no banner and no sound. Counting goes on, exactly as
/// with the Quiet chosen in the panel (Quiet is about banners; Pause is about the camera).
///
/// Like `BreakSchedule` and `RoutineDay`, this is a rule about time that owns no clock:
/// it is handed the moment and the calendar, and is tested on moments written by hand.
///
/// Three cases worth knowing:
///   - `start` before `end` (09:00 to 18:00): the hours of one day.
///   - `start` after `end` (22:00 to 06:00): a night shift. The hours belong to the day
///     they START on: with Friday chosen and Saturday not, Friday 23:00 and Saturday
///     03:00 are inside, Saturday 23:00 is not.
///   - `start` equal to `end`: the 24 hours from that time, by the same rule.
public struct WorkingHours: Equatable {

    public var start: TimeOfDay
    public var end: TimeOfDay
    /// 1 = Sunday ... 7 = Saturday, as `Calendar` counts them.
    public var weekdays: Set<Int>

    public init(start: TimeOfDay, end: TimeOfDay, weekdays: Set<Int>) {
        self.start = start
        self.end = end
        self.weekdays = weekdays
    }

    /// Monday to Friday, 09:00 to 18:00: what the Settings window starts from.
    public static let usual = WorkingHours(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 18), weekdays: [2, 3, 4, 5, 6])

    /// Is this moment inside the working hours?
    public func contains(_ now: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return true }
        let time = TimeOfDay(hour: hour, minute: minute)
        if start < end {
            return weekdays.contains(weekday) && time >= start && time < end
        }
        // Over midnight: the evening of a chosen day, or the early morning after one.
        let dayBefore = weekday == 1 ? 7 : weekday - 1
        return (weekdays.contains(weekday) && time >= start) || (weekdays.contains(dayBefore) && time < end)
    }

    /// The next moment the working hours begin, strictly after `now`. Nil with no day
    /// chosen: they never begin.
    public func nextStart(after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        // Eight days: today's start may already be behind, and the same weekday comes back.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let begins = calendar.date(bySettingHour: start.hour, minute: start.minute, second: 0, of: day),
                  begins > now else { continue }
            return begins
        }
        return nil
    }
}
