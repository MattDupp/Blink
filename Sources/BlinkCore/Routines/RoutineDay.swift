import Foundation

/// One planned time of a routine on one day, and where it stands.
public struct RoutineSlot: Equatable, Identifiable {

    public enum Status: Equatable {
        /// Its time has not come yet.
        case upcoming
        /// Its time has come and it is waiting for you.
        case due
        /// You put it off until then.
        case later(until: Date)
        case done(at: Date)
        /// Its next time came first: it was dropped, not piled up.
        case missed
        /// Its time had already passed when the routine was switched on: never asked for.
        case notAsked
    }

    /// The routine's `id`.
    public let routine: String
    /// The name of this planned time in the record: the day and the time ON THE WALL
    /// CLOCK, "2026-11-20T08:00", with no time zone.
    ///
    /// Why not the moment itself? Because "today's 08:00" must stay the same thing when
    /// the clock is moved. Done at 08:00 in Paris, then a flight to New York: when 08:00
    /// comes round again on the same date, it is already done. A moment (08:00 Paris =
    /// 02:00 New York) would not match, and the reminder would come twice.
    public let key: String
    public let time: TimeOfDay
    /// The moment it falls due, on this Mac's clock as it is set now.
    public let due: Date
    /// The moment it is dropped if still not done: the routine's next time, or midnight.
    public let end: Date
    public let status: Status

    public var id: String { routine + " " + key }
}

/// A routine's day: its planned times and where each stands. THE one place that decides
/// what is due.
///
/// It is a pure function of four things: the routine, the record, the clock and the
/// calendar (and, for a routine "at the screen", the count of time at the screen, which
/// is handed in: see `ScreenCount`). Nothing here is stored, so nothing can go stale: the Mac can sleep through a
/// time, the app can start after it, the time zone can change, and the answer is simply
/// worked out again from the record.
///
/// The rules:
///   - a time is due from its moment until the routine's next time that day, or midnight
///     for the last one. After that it is `missed`: two reminders never pile up;
///   - `done` wins over everything, whenever it was recorded;
///   - `later` hides it until the chosen moment (but not past its end);
///   - a time that daylight saving skips (02:30 on the night the clocks go forward) falls
///     due at the next minute that exists; a time that happens twice falls due once.
///
/// WHERE A NEW KIND OF SCHEDULE PLUGS IN: `slots(of:on:record:now:calendar:)` switches on
/// the schedule. A new kind returns its own slots there, each with a `key` that names the
/// planned occasion in the record. Everything after that - the record, Done and Later,
/// the banner rules, the menu-bar dot - works on slots and does not look at the schedule.
/// "Three times a week" is done this way: `RoutineWeek` says whether the day asks, and
/// the day then has one slot, named by the day alone ("2026-11-20").
public struct RoutineDay: Equatable {

    public let routine: Routine
    /// Today's planned times, in order.
    public let slots: [RoutineSlot]
    /// For a routine counted by the week: where the week stands. It is there on every day
    /// of the week, also on the days with no slot (nothing is asked, or the count is reached).
    public let week: RoutineWeek?
    /// For a routine "at the screen": its count. Nil for the other kinds, and while it is off.
    public let screen: ScreenCount?

    public init(routine: Routine, record: [RoutineEvent], now: Date, calendar: Calendar = .current,
                screen: ScreenCount? = nil) {
        self.routine = routine
        slots = Self.slots(of: routine, on: now, record: record, now: now, calendar: calendar, screen: screen)
        self.screen = routine.isOn && routine.screenMinutes != nil ? (screen ?? ScreenCount()) : nil
        week = routine.isOn ? RoutineWeek(routine: routine, record: record, on: now, calendar: calendar) : nil
    }

    /// The time waiting for you now, if any. At most one: an older one has been dropped.
    public var due: RoutineSlot? {
        slots.first { $0.status == .due }
    }

    /// The next time still to come today.
    public var next: RoutineSlot? {
        slots.first { $0.status == .upcoming }
    }

    /// The time you put off, while it is put off.
    public var putOff: RoutineSlot? {
        slots.first { if case .later = $0.status { return true } else { return false } }
    }

    /// For a routine "at the screen": whole minutes at the screen before it asks again.
    public var minutesLeft: Int? {
        guard let screen, let minutes = routine.screenMinutes else { return nil }
        return screen.minutesLeft(of: minutes)
    }

    /// The planned times of `routine` on the day that holds `day`, judged at `now`.
    /// `screen` is only read for a routine "at the screen", and only says something
    /// about today.
    public static func slots(of routine: Routine, on day: Date, record: [RoutineEvent], now: Date,
                             calendar: Calendar = .current, screen: ScreenCount? = nil) -> [RoutineSlot] {
        guard routine.isOn else { return [] }
        switch routine.schedule {
        case .timesOfDay(_, let weekdays):
            return timeSlots(of: routine, weekdays: weekdays, on: day, record: record, now: now, calendar: calendar)
        case .timesPerWeek(_, _, let time):
            return weekSlot(of: routine, time: time, on: day, record: record, now: now, calendar: calendar)
        case .everyMinutesAtScreen:
            return screenSlot(of: routine, screen: screen, on: day, record: record, now: now, calendar: calendar)
        }
    }

    /// The one slot of a routine "at the screen": the occasion its count last opened
    /// today, if any. It waits until midnight, or until the count opens the next one or
    /// closes it (see `ScreenCount`). It leaves no `missed` line: it is simply replaced.
    private static func screenSlot(of routine: Routine, screen: ScreenCount?, on day: Date, record: [RoutineEvent],
                                   now: Date, calendar: Calendar) -> [RoutineSlot] {
        guard let occasion = screen?.open, calendar.isDate(day, inSameDayAs: now),
              calendar.isDate(occasion.due, inSameDayAs: day),
              let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return [] }
        let events = record.filter { $0.routine == routine.id && $0.slot == occasion.key }
        let time = TimeOfDay(hour: calendar.component(.hour, from: occasion.due),
                             minute: calendar.component(.minute, from: occasion.due))
        return [RoutineSlot(routine: routine.id, key: occasion.key, time: time, due: occasion.due, end: midnight,
                            status: status(due: occasion.due, end: midnight, events: events, onSince: nil, now: now))]
    }

    /// The one slot of a day that asks, for a routine counted by the week; none on a day
    /// that does not ask. It waits from its time until midnight.
    private static func weekSlot(of routine: Routine, time: TimeOfDay, on day: Date, record: [RoutineEvent],
                                 now: Date, calendar: Calendar) -> [RoutineSlot] {
        guard let week = RoutineWeek(routine: routine, record: record, on: day, calendar: calendar),
              week.today.asks else { return [] }
        let start = week.today.start
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: start),
              let due = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: start),
              due >= start, due < midnight else { return [] }
        let key = week.today.key
        let events = record.filter { $0.routine == routine.id && $0.slot == key }
        return [RoutineSlot(routine: routine.id, key: key, time: time, due: due, end: midnight,
                            status: status(due: due, end: midnight, events: events, onSince: routine.onSince, now: now))]
    }

    /// The events that still stand: each `undone` takes away the latest `done` before it.
    public static func standing(_ events: [RoutineEvent]) -> [RoutineEvent] {
        var kept: [RoutineEvent] = []
        for event in events {
            if event.action == .undone {
                if let last = kept.lastIndex(where: { $0.action == .done }) { kept.remove(at: last) }
            } else {
                kept.append(event)
            }
        }
        return kept
    }

    private static func timeSlots(of routine: Routine, weekdays: Set<Int>?, on day: Date, record: [RoutineEvent],
                                  now: Date, calendar: Calendar) -> [RoutineSlot] {
        let start = calendar.startOfDay(for: day)
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        if let weekdays, !weekdays.contains(calendar.component(.weekday, from: start)) { return [] }
        let date = calendar.dateComponents([.year, .month, .day], from: start)
        let dayText = String(format: "%04d-%02d-%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0)

        // Each time as a moment of this day. For a time the clock skips, the calendar
        // answers with the next minute that exists.
        var planned: [(time: TimeOfDay, due: Date)] = routine.times.compactMap { time in
            guard let due = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: start),
                  due >= start, due < midnight else { return nil }
            return (time, due)
        }
        // Two times that land on the same moment (both skipped by the clock): one reminder.
        planned = planned.enumerated().compactMap { index, slot in
            index + 1 < planned.count && planned[index + 1].due <= slot.due ? nil : slot
        }

        let mine = record.filter { $0.routine == routine.id }
        return planned.enumerated().map { index, slot in
            let key = "\(dayText)T\(slot.time.text)"
            let end = index + 1 < planned.count ? planned[index + 1].due : midnight
            let events = mine.filter { $0.slot == key }
            return RoutineSlot(routine: routine.id, key: key, time: slot.time, due: slot.due, end: end,
                               status: status(due: slot.due, end: end, events: events, onSince: routine.onSince, now: now))
        }
    }

    private static func status(due: Date, end: Date, events: [RoutineEvent], onSince: Date?,
                               now: Date) -> RoutineSlot.Status {
        let events = standing(events)
        if let done = events.last(where: { $0.action == .done }) { return .done(at: done.at) }
        if now < due { return .upcoming }
        if let onSince, due < onSince { return .notAsked }
        if now >= end { return .missed }
        if let until = events.last(where: { $0.action == .later })?.until, now < until { return .later(until: until) }
        return .due
    }

    /// The `missed` lines the record still lacks: times of today and yesterday that were
    /// dropped without being done. Written so that "how well was it kept" can be answered
    /// later from the file alone. (Days on which the app never ran leave no line at all.)
    public static func unrecordedMisses(routines: [Routine], record: [RoutineEvent], now: Date,
                                        calendar: Calendar = .current) -> [RoutineEvent] {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        var missing: [RoutineEvent] = []
        for routine in routines {
            for day in [yesterday, now] {
                for slot in slots(of: routine, on: day, record: record, now: now, calendar: calendar)
                where slot.status == .missed {
                    let known = record.contains { $0.routine == slot.routine && $0.slot == slot.key && $0.action == .missed }
                    if !known { missing.append(RoutineEvent(at: slot.end, routine: slot.routine, slot: slot.key, action: .missed)) }
                }
            }
        }
        return missing
    }
}

/// When a due time earns a banner. Gentle on purpose:
///   - only while somebody is at the screen: a banner shown to an empty chair is lost,
///     so it is kept until you are back;
///   - once, and once more ten minutes later if you touched nothing. Then no more banners:
///     the mark in the menu bar and the line in the panel stay until it is done;
///   - after "Later", the same again from the moment you chose;
///   - a routine "at the screen" is not repeated: it comes back by itself;
///   - ONE AT A TIME, over all routines: two banners are at least five minutes apart, and
///     no more than four are shown in an hour. A reminder held back by this is not lost:
///     the mark in the menu bar and the panel show it at once, and its banner comes when
///     there is room (`mayShow`, `order`).
public struct RoutinePolicy {

    /// The least time between two routine banners, whatever the routines.
    public var gapMinutes = 5
    /// The most routine banners in any hour, over all routines.
    public var bannersPerHour = 4

    /// How long "Later" puts a reminder off.
    public var laterMinutes = 15
    public var repeatAfterMinutes = 10
    public var bannersPerSlot = 2

    public init() {}

    /// The moment "Later", pressed at `now`, puts a reminder off to.
    public func later(from now: Date) -> Date {
        now.addingTimeInterval(Double(laterMinutes) * 60)
    }

    /// True when a banner for `slot` should be shown now.
    /// `repeats` false: one banner only (a routine "at the screen").
    public func bannerDue(for slot: RoutineSlot, record: [RoutineEvent], now: Date, someoneThere: Bool,
                          repeats: Bool = true) -> Bool {
        guard slot.status == .due, someoneThere else { return false }
        var events = record.filter { $0.routine == slot.routine && $0.slot == slot.key }
        // Banners shown before a "Later" do not count against the ones after it.
        if let later = events.lastIndex(where: { $0.action == .later }) { events.removeSubrange(...later) }
        let shown = events.filter { $0.action == .shown }
        guard let last = shown.last else { return true }
        return repeats && shown.count < bannersPerSlot && now.timeIntervalSince(last.at) >= Double(repeatAfterMinutes) * 60
    }

    /// True when there is room for one more routine banner now: the last one, of any
    /// routine, is far enough back, and the hour is not full.
    public func mayShow(record: [RoutineEvent], now: Date) -> Bool {
        let shown = record.filter { $0.action == .shown && $0.at <= now }
        if let last = shown.last, now.timeIntervalSince(last.at) < Double(gapMinutes) * 60 { return false }
        return shown.filter { now.timeIntervalSince($0.at) < 3600 }.count < bannersPerHour
    }

    /// Who goes first when several are due: one that has had no banner yet before the
    /// repeat of another, then a time of day or of the week before a routine "at the
    /// screen" (which comes back anyway), then the one waiting longest.
    public func order(_ days: [RoutineDay], record: [RoutineEvent] = []) -> [RoutineDay] {
        let shown = Set(record.filter { $0.action == .shown }.map { $0.routine + " " + $0.slot })
        return days.sorted { left, right in
            let (seenLeft, seenRight) = (shown.contains(left.due?.id ?? ""), shown.contains(right.due?.id ?? ""))
            if seenLeft != seenRight { return !seenLeft }
            let (a, b) = (left.screen != nil, right.screen != nil)
            if a != b { return !a }
            return (left.due?.due ?? .distantFuture) < (right.due?.due ?? .distantFuture)
        }
    }
}
