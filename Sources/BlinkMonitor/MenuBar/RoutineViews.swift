import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// MARK: - In the panel

/// Today's routines in the panel: each time of the day and where it stands, and Done and
/// Later while one is waiting. Draws nothing at all when no routine is switched on, so the
/// panel of someone who does not use routines is unchanged.
///
/// IT STAYS SMALL however many routines there are. With one or two, each is drawn in
/// full. With more, only what waits is drawn in full, then one line for what comes next;
/// the others are one click away ("All 5 routines").
struct RoutineBlock: View {
    @ObservedObject var routines: RoutineController
    let now: Date

    var body: some View {
        // The timer is an object of its own: a second view watches it, so that the panel
        // redraws when a timer starts or ends.
        RoutineList(routines: routines, session: routines.session, now: now)
    }
}

private struct RoutineList: View {
    @ObservedObject var routines: RoutineController
    @ObservedObject var session: RoutineSessionController
    let now: Date

    var body: some View {
        let days = routines.days(now: now)
        if !days.isEmpty {
            let folds = days.count > RoutineFold.shownInFull && !routines.showsAll
            let quiet = routines.isQuiet(now: now)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SectionTitle("Routines")
                    Spacer(minLength: 8)
                    // One Quiet for everything, at the foot of the panel. This older one,
                    // for routines only, is no longer offered: it is only shown, with its
                    // way out, for someone who had it on.
                    if quiet {
                        Text("Routines quiet until tomorrow")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Undo") { routines.setQuiet(false) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Show routine reminders again")
                    }
                }
                ForEach(folds ? days.filter { isActive($0) } : days, id: \.routine.id) { day in
                    row(day)
                }
                if folds, let next = RoutineFold.next(of: days.filter { !isActive($0) }, now: now) {
                    Label(next, systemImage: "arrow.turn.down.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if days.count > RoutineFold.shownInFull {
                    Button(routines.showsAll ? "Show Less" : "Show All \(days.count)") { routines.showsAll.toggle() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(16)
            Divider()
        }
    }

    /// Something of this routine needs you now: a time waits or was put off, or its timer runs.
    private func isActive(_ day: RoutineDay) -> Bool {
        day.due != nil || day.putOff != nil || session.session?.routine == day.routine.id
    }

    @ViewBuilder
    private func row(_ day: RoutineDay) -> some View {
        let running = session.session?.routine == day.routine.id ? session.session : nil
        if let week = day.week {
            WeekRow(day: day, week: week, running: running, isOpen: routines.openWeeks.contains(day.routine.id),
                    toggle: {
                        if routines.openWeeks.contains(day.routine.id) { routines.openWeeks.remove(day.routine.id) }
                        else { routines.openWeeks.insert(day.routine.id) }
                    },
                    calendar: routines.calendar, laterMinutes: routines.policy.laterMinutes,
                    actions: WeekRow.Actions(
                        didIt: { routines.didIt(day.routine.id) }, undo: { routines.undo(day.routine.id) },
                        later: { routines.later($0) }, start: { routines.startSession(day.routine.id) },
                        stop: { session.stop() }))
        } else {
            RoutineRow(day: day, running: running, done: { routines.done($0) }, later: { routines.later($0) },
                       start: { routines.startSession(day.routine.id) }, stop: { session.stop() },
                       laterMinutes: routines.policy.laterMinutes)
        }
    }
}

/// What the folded panel says of the routines it does not draw.
enum RoutineFold {

    /// Up to this many routines are each drawn in full.
    static let shownInFull = 2

    /// "Next: Eye drops at 17:00": the soonest thing still to come today among `days`.
    /// A routine "at the screen" has no time on the clock: it is placed as if you stayed.
    static func next(of days: [RoutineDay], now: Date) -> String? {
        let coming: [(at: Date, text: String)] = days.compactMap { day in
            if let minutes = day.minutesLeft {
                return (now.addingTimeInterval(Double(minutes) * 60), "\(day.routine.title) in about \(minutes) min at the screen")
            }
            guard let slot = day.next else { return nil }
            return (slot.due, "\(day.routine.title) at \(Format.time(slot.due))")
        }
        return coming.min { $0.at < $1.at }.map { "Next: " + $0.text }
    }
}

/// A routine counted by the week: how far the week is, its seven days, and what can be
/// done now. "Done" is always there: doing it early, or on a day that did not ask,
/// counts like any other.
private struct WeekRow: View {

    struct Actions {
        var didIt: () -> Void = {}
        var undo: () -> Void = {}
        var later: (RoutineSlot) -> Void = { _ in }
        var start: () -> Void = {}
        var stop: () -> Void = {}
    }

    let day: RoutineDay
    let week: RoutineWeek
    /// This routine's timer, while it runs.
    let running: RoutineSession?
    /// Its days and buttons were opened by a click.
    var isOpen = false
    var toggle: () -> Void = {}
    let calendar: Calendar
    let laterMinutes: Int
    let actions: Actions

    /// Nothing waits, nothing runs and nothing was done today: one line says it all. It
    /// took about 110 points before, with both buttons, on days that asked for nothing.
    private var folded: Bool {
        !isOpen && running == nil && day.due == nil && day.putOff == nil && week.today.done == 0
    }

    var body: some View {
        if folded {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: day.routine.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 16)
                    Text(day.routine.title)
                    Spacer(minLength: 8)
                    Text("\(week.done) of \(week.target) · \(state)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the week, and mark it done")
        } else {
            unfolded
        }
    }

    private var unfolded: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: day.routine.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                Text(day.routine.title)
                Spacer(minLength: 8)
                Text("\(week.done) of \(week.target) this week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isOpen && running == nil && day.due == nil && day.putOff == nil && week.today.done == 0 {
                    Button(action: toggle) {
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Show less")
                }
            }
            HStack(spacing: 5) {
                ForEach(Array(week.days.enumerated()), id: \.element.id) { index, weekDay in
                    DayChip(day: weekDay, place: index < week.todayIndex ? .past : index == week.todayIndex ? .today : .toCome,
                            planned: planned.contains(index), calendar: calendar)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(state)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if running == nil, week.today.done > 0 {
                        Button("Undo") { actions.undo() }
                            .buttonStyle(.link)
                            .help("Take back the last one marked today")
                    }
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if running != nil {
                        Button("Stop Timer") { actions.stop() }
                            .help("Ends the timer without marking it done")
                    } else {
                        if let slot = day.due {
                            Button("Later (\(laterMinutes) min)") { actions.later(slot) }
                                .help("Remind me again in \(Format.count(laterMinutes, "minute"))")
                        }
                        if let minutes = day.routine.sessionMinutes {
                            Button("Start Timer") { actions.start() }
                                .help("\(Format.count(minutes, "minute")). The camera is paused meanwhile, a sound marks the end, and it is marked done.")
                        }
                        Button("Done") { actions.didIt() }
                            .help("Counts for this week, whatever the day or the hour")
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isWaiting ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .contain)
    }

    private var isWaiting: Bool { running == nil && day.due != nil }

    /// The days drawn with a ring: where the times still to do would fall, from today on,
    /// if each is done on the first day that asks. With two of three done on a Friday
    /// that is Friday alone, not the weekend too.
    private var planned: Set<Int> {
        let open = week.days.indices.filter { $0 >= week.todayIndex && week.days[$0].asks && week.days[$0].done == 0 }
        return Set(open.prefix(max(week.target - week.done, 0)))
    }

    /// Where things stand, in a few words, said as what is, not as a reproach.
    private var state: String {
        if let running { return "Timer running until \(Format.time(running.end)). The camera is paused." }
        if let slot = day.due { return "Waiting since \(Format.time(slot.due))" }
        if let slot = day.putOff, case .later(let until) = slot.status { return "Later, at \(Format.time(until))" }
        if week.today.done > 1 { return "Done \(week.today.done) times today" }
        if week.today.done == 1 { return week.isReached ? "Done today. Week complete." : "Done today" }
        if week.isReached { return "Done for this week" }
        if let slot = day.next { return "Today at \(Format.time(slot.due))" }
        if let next = week.nextAsk { return "Next on \(calendar.weekdaySymbols[next.weekday - 1])" }
        return "Nothing more this week"
    }
}

/// One day of the week: its letter, a tick when it was done.
private struct DayChip: View {

    enum Place { case past, today, toCome }

    let day: RoutineWeek.Day
    let place: Place
    /// One of the times still to do is expected on this day (see `WeekRow.planned`).
    let planned: Bool
    let calendar: Calendar

    var body: some View {
        VStack(spacing: 3) {
            Text(calendar.veryShortWeekdaySymbols[day.weekday - 1])
                .font(.caption2.weight(place == .today ? .bold : .regular))
                .foregroundStyle(place == .today ? .primary : .secondary)
            ZStack {
                Circle()
                    .fill(day.done > 0 ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                if planned {
                    Circle().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.2)
                }
                if day.done > 1 {
                    Text("\(day.done)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                } else if day.done == 1 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 22, height: 22)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(calendar.weekdaySymbols[day.weekday - 1]): \(spoken)")
    }

    private var spoken: String {
        if day.done > 1 { return "done \(day.done) times" }
        if day.done == 1 { return "done" }
        if planned { return place == .today ? "asked today" : "to come" }
        return place == .past ? "not done" : "nothing due"
    }
}

/// One routine: its name, what comes next, its times, and the two buttons when needed.
private struct RoutineRow: View {
    let day: RoutineDay
    /// This routine's timer, while it runs.
    var running: RoutineSession?
    let done: (RoutineSlot) -> Void
    let later: (RoutineSlot) -> Void
    var start: () -> Void = {}
    var stop: () -> Void = {}
    let laterMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: day.routine.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                Text(day.routine.title)
                Spacer(minLength: 8)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The times, side by side. With too many to fit, the summary above says enough.
            // (A routine "at the screen" has no times to list.)
            if day.screen == nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(day.slots) { TimeChip(slot: $0) }
                    }
                    EmptyView()
                }
            }
            if let running {
                HStack(spacing: 6) {
                    Text("Timer running until \(Format.time(running.end)). The camera is paused.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Stop Timer") { stop() }
                        .help("Ends the timer without marking it done")
                }
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            } else if let slot = day.due {
                waiting("Waiting since \(Format.time(slot.due))",
                        slot: slot, offerLater: true)
            } else if let slot = day.putOff, case .later(let until) = slot.status {
                waiting("\(Format.time(slot.due)), later at \(Format.time(until))", slot: slot, offerLater: false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func waiting(_ text: String, slot: RoutineSlot, offerLater: Bool) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if offerLater {
                Button("Later (\(laterMinutes) min)") { later(slot) }
                    .help("Remind me again in \(Format.count(laterMinutes, "minute"))")
            }
            if let minutes = day.routine.sessionMinutes {
                Button("Start Timer") { start() }
                    .help("\(Format.count(minutes, "minute")). The camera is paused meanwhile, a sound marks the end, and it is marked done.")
            }
            Button("Done") { done(slot) }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// What the day looks like in a few words, said as what was done, not as a reproach.
    private var summary: String {
        if let every = day.routine.screenMinutes, let left = day.minutesLeft {
            return day.due != nil || day.putOff != nil ? "Every \(every) min at the screen"
                                                       : "In about \(left) min at the screen"
        }
        let count = day.slots.count
        let done = day.slots.filter { if case .done = $0.status { return true } else { return false } }.count
        if done == count { return "All done today" }
        if let next = day.next, day.due == nil, day.putOff == nil { return "Next at \(Format.time(next.due))" }
        return "\(done) of \(count) done"
    }
}

/// One time of the day, drawn by where it stands.
private struct TimeChip: View {
    let slot: RoutineSlot

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
            }
            Text(Format.time(slot.due))
                .strikethrough(slot.status == .missed)
                .monospacedDigit()
        }
        .font(.caption.weight(isWaiting ? .semibold : .regular))
        .foregroundStyle(style)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isWaiting ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.time(slot.due)): \(spoken)")
    }

    private var isWaiting: Bool {
        switch slot.status {
        case .due, .later: return true
        default: return false
        }
    }

    private var symbol: String? {
        switch slot.status {
        case .done: return "checkmark"
        case .later: return "clock"
        default: return nil
        }
    }

    private var style: AnyShapeStyle {
        switch slot.status {
        case .due, .later: return AnyShapeStyle(.tint)
        case .upcoming: return AnyShapeStyle(.primary)
        case .done: return AnyShapeStyle(.secondary)
        case .missed, .notAsked: return AnyShapeStyle(.tertiary)
        }
    }

    private var spoken: String {
        switch slot.status {
        case .upcoming: return "to come"
        case .due: return "waiting"
        case .later: return "later"
        case .done: return "done"
        case .missed: return "not done"
        case .notAsked: return "not due today"
        }
    }
}

// MARK: - In Settings

/// What Settings says about a routine, in one place.
enum RoutineWords {

    /// Under the list. Two sentences: the long footnote carried rules nobody read, and
    /// each routine's line now says how its own reminders come.
    static let footnote = "Blink Monitor reminds you of routines that you, or your eye-care professional, chose. "
        + "It does not say what to use or how often."

    /// A time of day as this Mac writes it: "08:00", or "8:00 AM".
    static func time(_ time: TimeOfDay, calendar: Calendar = .current) -> String {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date(timeIntervalSinceReferenceDate: 0))
            .map(Format.time) ?? time.text
    }

    /// One line that says when a routine comes: "08:00, 13:00 and 17:00, every day".
    static func summary(_ routine: Routine, calendar: Calendar = .current, policy: RoutinePolicy = RoutinePolicy()) -> String {
        switch routine.schedule {
        case .timesOfDay(_, let weekdays):
            let times = routine.times.map { time($0, calendar: calendar) }
            let listed = times.count > 1 ? times.dropLast().joined(separator: ", ") + " and " + (times.last ?? "") : times.first ?? "No time"
            return "\(listed), \(days(weekdays, calendar: calendar))"
        case .timesPerWeek(let count, _, let at):
            return "\(count == 1 ? "Once" : "\(count) times") a week, at \(time(at, calendar: calendar))"
                + (routine.sessionMinutes.map { ", with a timer of \(Format.count($0, "minute"))" } ?? "")
        case .everyMinutesAtScreen(let minutes):
            return "Every \(Format.count(minutes, "minute")) at the screen"
        }
    }

    /// "every day", "on Mon, Wed and Fri".
    static func days(_ weekdays: Set<Int>?, calendar: Calendar = .current) -> String {
        guard let weekdays, weekdays.count < 7 else { return "every day" }
        let ordered = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }.filter(weekdays.contains)
        let names = ordered.map { calendar.shortWeekdaySymbols[$0 - 1] }
        return "on " + (names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "") : names.first ?? "")
    }
}

/// The Routines tab: each routine with its switch and its times, and a test reminder.
/// A routine of your own has four more things on its card: its name, its symbol, its
/// kind of schedule, and Delete. "Add a Routine" offers a few starting points.
///
/// The wording is deliberate: the app reminds you of a routine you chose. It gives no
/// advice on what to do for your eyes or how often.
struct RoutineSettings: View {
    @ObservedObject var routines: RoutineController
    var moment = Moment()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cards
            HStack(spacing: 12) {
                Menu("Add a Routine") {
                    ForEach(RoutineTemplate.all) { template in
                        Button(template.summary) { routines.add(template) }
                    }
                    // The built-in ones that were removed can come back.
                    if !routines.hiddenBuiltIn.isEmpty {
                        Divider()
                        ForEach(routines.hiddenBuiltIn) { routine in
                            Button(routine.title) { routines.unhide(routine.id) }
                        }
                    }
                }
                .fixedSize()
                .disabled(!routines.canAdd && routines.hiddenBuiltIn.isEmpty)
                Text(routines.canAdd ? "A routine of your own. You can change everything afterwards. It is switched on at once."
                                     : "That is the most routines of your own (\(RoutineController.mostOwn)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Card {
                Row("Routine log", detail: "One line each time a reminder is shown, done, postponed or missed. It stays on this Mac and opens in any spreadsheet.") {
                    Button("Show in Finder") { showRecord() }
                }
            }
            Text(RoutineWords.footnote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line per routine. A click opens its editor, one at a time: every card used to
    /// be a full editor, always open, and two of them filled the screen.
    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Your own routines first, the newest on top: a routine just added appears
            // where you are looking, not under the fold of the list.
            ForEach(routines.routines.filter { !$0.isBuiltIn }.reversed() + routines.routines.filter { $0.isBuiltIn && !$0.isHidden }) { routine in
                Card {
                    header(routine)
                    if routines.openCard == routine.id { editor(routine) }
                }
            }
        }
    }

    /// The line of a routine: its name, when it comes, its switch.
    private func header(_ routine: Routine) -> some View {
        let open = routines.openCard == routine.id
        return HStack(spacing: 10) {
            Button { routines.openCard = open ? nil : routine.id } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: routine.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routine.title)
                        Text(RoutineWords.summary(routine, calendar: routines.calendar, policy: routines.policy))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Show less" : "Change its times and its settings")
            .accessibilityLabel("\(routine.title), settings")
            .accessibilityValue(open ? "open" : "closed")
            Toggle(routine.title, isOn: Binding(get: { routine.isOn }, set: { routines.setOn(routine.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// What opens under the line: the rows of this kind of schedule, the timer, the sound.
    @ViewBuilder
    private func editor(_ routine: Routine) -> some View {
        own(routine)
        switch routine.schedule {
        case .timesOfDay(_, let weekdays): timeRows(for: routine, weekdays: weekdays)
        case .timesPerWeek(let count, let weekdays, let time): weekRows(for: routine, count: count, weekdays: weekdays, time: time)
        case .everyMinutesAtScreen(let minutes): screenRows(for: routine, minutes: minutes)
        }
        timer(routine)
        Divider()
        Row("A sound with its reminder", detail: "Off: its banner comes in silence, like every routine at first.") {
            Toggle("A sound with its reminder", isOn: Binding(get: { routine.playsSound }, set: { routines.setSound(routine.id, $0) }))
        }
        Divider()
        HStack(spacing: 12) {
            if case .timesOfDay = routine.schedule {
                let full = routines.shownTimes(of: routine).count >= 12
                Button("Add a Time") { routines.addTimeRow(routine.id) }
                    .disabled(full)
                    .help(full ? "Twelve times at most" : "One more time of day for this routine")
            }
            Spacer(minLength: 12)
            foot(routine)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// A routine at times of day: its times, and the days of the week it asks on.
    @ViewBuilder
    private func timeRows(for routine: Routine, weekdays: Set<Int>?) -> some View {
        // By position, not by time: a row keeps its place (and the keyboard) while its time is typed.
        // And in the order entered while the window is open (`RoutineController.shownTimes`).
        ForEach(Array(routines.shownTimes(of: routine).enumerated()), id: \.offset) { index, time in
            Divider()
            timeRow(routine, index: index, time: time)
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text("On these days")
            dayChips(chosen: weekdays ?? Set(1...7)) { weekday, on in routines.setDay(routine.id, weekday, on: on) }
            Text("All seven: every day. Choose at least one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// A routine "at the screen": its minutes.
    @ViewBuilder
    private func screenRows(for routine: Routine, minutes: Int) -> some View {
        Divider()
        Row("Every", detail: "Counted while you are at the screen. The count restarts when you press Done, "
            + "after \(Format.count(Int(ScreenCount.awaySeconds / 60), "minute")) away, and each day.") {
            HStack(spacing: 6) {
                Text(Format.count(minutes, "minute")).monospacedDigit().fixedSize()
                Stepper("Minutes at the screen", value: Binding(get: { minutes }, set: { routines.setScreenMinutes(routine.id, $0) }),
                        in: RoutineSchedule.screenMinutes, step: 5)
                    .accessibilityValue("\(minutes)")
            }
        }
    }

    // MARK: What every card shares

    /// For a routine of your own: its name with its symbol, and when it comes. Nothing for
    /// a built-in one. Each is a labelled row, like every other setting: there were three
    /// controls in a line with no word beside them.
    @ViewBuilder
    private func own(_ routine: Routine) -> some View {
        if !routine.isBuiltIn {
            Divider()
            Row("Name", detail: "Shown on its reminder and in the panel.") {
                Picker("Symbol", selection: Binding(get: { routine.symbol }, set: { routines.setSymbol(routine.id, $0) })) {
                    ForEach(Routine.symbols, id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                    }
                }
                .labelsHidden()
                .fixedSize()
                // The field edits the stored name directly; `rename` keeps it to one
                // short line whatever is typed or pasted.
                TextField("Name", text: Binding(get: { routine.name }, set: { routines.rename(routine.id, $0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .accessibilityLabel("Name of the routine")
            }
            Divider()
            Row("When", detail: "Changing this keeps what you set for the other kinds while the window is open.") {
                Picker("Kind of schedule", selection: Binding(get: { routine.schedule.kind },
                                                              set: { routines.setKind(routine.id, $0) })) {
                    Text("At times of day").tag(RoutineSchedule.Kind.timesOfDay)
                    Text("Times a week").tag(RoutineSchedule.Kind.timesPerWeek)
                    Text("At the screen").tag(RoutineSchedule.Kind.atScreen)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// The timer's rows. A built-in routine shows its timer when it has one; a routine of
    /// your own can be given one, or have it taken away.
    @ViewBuilder
    private func timer(_ routine: Routine) -> some View {
        let detail = "Set the length given in your product's instructions. While it runs the camera is paused, "
            + "the Mac stays awake, and a sound marks the end. Then it is marked done."
        if !routine.isBuiltIn {
            Divider()
            Row("Timer", detail: routine.sessionMinutes == nil ? "For something that takes a while: Start Timer is added to its reminder." : detail) {
                HStack(spacing: 6) {
                    if let minutes = routine.sessionMinutes {
                        Text(Format.count(minutes, "minute")).monospacedDigit().fixedSize()
                        Stepper("Length of the timer, in minutes",
                                value: Binding(get: { minutes }, set: { routines.setSessionMinutes(routine.id, $0) }), in: 1...60)
                            .accessibilityValue("\(minutes)")
                    }
                    Toggle("Timer", isOn: Binding(get: { routine.sessionMinutes != nil }, set: { routines.setTimer(routine.id, $0) }))
                }
            }
        } else if let minutes = routine.sessionMinutes {
            Divider()
            Row("Timer", detail: detail) {
                HStack(spacing: 6) {
                    Text(Format.count(minutes, "minute")).monospacedDigit().fixedSize()
                    Stepper("Length of the timer, in minutes",
                            value: Binding(get: { minutes }, set: { routines.setSessionMinutes(routine.id, $0) }), in: 1...60)
                        .accessibilityValue("\(minutes)")
                }
            }
        }
    }

    /// The end of a card: Delete for a routine of your own, Remove for a built-in one,
    /// and the test reminder.
    @ViewBuilder
    private func foot(_ routine: Routine) -> some View {
        if routine.isBuiltIn {
            Button("Remove") { routines.hide(routine.id) }
                .help("Takes it out of this list and switches it off. Add a Routine brings it back, with its times.")
        } else {
            Button("Delete…", role: .destructive) { confirmDelete(routine) }
        }
        Button("Send a Test Reminder") { routines.sendTest(routine.id) }
            .help("Shows the reminder now. Its buttons do nothing on a test.")
    }

    /// Asks before deleting, and says what happens to the record.
    private func confirmDelete(_ routine: Routine) {
        // The same question as every other erasing action (`Confirm`): Cancel is the default.
        let question = Confirm.Question(title: "Delete “\(routine.title)”?",
                                        text: "Its reminders stop. What you did with it stays in the routine log. This cannot be undone.",
                                        button: "Delete")
        if Confirm.destructive(question) { routines.remove(routine.id) }
    }

    /// A routine counted by the week: its count, the days it asks first and its time.
    @ViewBuilder
    private func weekRows(for routine: Routine, count: Int, weekdays: Set<Int>, time: TimeOfDay) -> some View {
        Divider()
        Row("Times a week", detail: "A weekly count, not fixed days. If you miss a day, it reminds you the next day. Mark it done at any time from the panel.") {
            HStack(spacing: 6) {
                Text("\(count)").monospacedDigit()
                Stepper("Times a week", value: Binding(get: { count }, set: { routines.setWeekCount(routine.id, $0) }),
                        in: 1...7)
                    .accessibilityValue("\(count)")
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Days and time")
                Spacer(minLength: 12)
                DatePicker("Time of the reminder", selection: Binding(
                    get: { Self.date(of: time, on: moment.now) },
                    set: { routines.setWeekTime(routine.id, Self.time(of: $0)) }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
            }
            dayChips(chosen: weekdays) { weekday, on in routines.setWeekday(routine.id, weekday, preferred: on) }
            Text("The days it reminds you first. Choose at least one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Seven days to choose from, in the order of this Mac's week: Monday first, or Sunday.
    private func dayChips(chosen: Set<Int>, set: @escaping (Int, Bool) -> Void) -> some View {
        let calendar = routines.calendar
        let ordered = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return HStack(spacing: 6) {
            ForEach(ordered, id: \.self) { weekday in
                let isChosen = chosen.contains(weekday)
                // A plain button drawn by hand: a system toggle button barely
                // shows which days are chosen when the window is not in front.
                Button { set(weekday, !isChosen) } label: {
                    Text(calendar.shortWeekdaySymbols[weekday - 1])
                        .font(.callout.weight(isChosen ? .semibold : .regular))
                        .foregroundStyle(isChosen ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(isChosen ? Color.accentColor : Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isChosen && chosen.count == 1 ? "A routine keeps at least one day" : "")
                .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                .accessibilityValue(isChosen ? "chosen" : "not chosen")
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
    }

    private func timeRow(_ routine: Routine, index: Int, time: TimeOfDay) -> some View {
        let only = routines.shownTimes(of: routine).count <= 1
        return HStack(spacing: 12) {
            Text("Time \(index + 1)")
                .foregroundStyle(routine.isOn ? .primary : .secondary)
            if let other = routines.double(of: index, in: routine) {
                // Two rows at one time are one reminder. Said, not silently merged.
                Text("Same as time \(other + 1): one reminder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            DatePicker("Time \(index + 1)", selection: Binding(
                get: { Self.date(of: time, on: moment.now) },
                set: { routines.setTime(routine.id, at: index, to: Self.time(of: $0)) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
            Button { routines.removeTime(routine.id, at: index) } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(only)
            .help(only ? "A routine keeps at least one time" : "Remove this time")
            .accessibilityLabel("Remove time \(index + 1)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// A date picker edits a date: the time is placed on today, and read back from it.
    private static func date(of time: TimeOfDay, on day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: calendar.startOfDay(for: day)) ?? day
    }

    private static func time(of date: Date, calendar: Calendar = .current) -> TimeOfDay {
        TimeOfDay(hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date))
    }

    /// The record file in the Finder, or its folder while nothing has been written yet.
    private func showRecord() {
        let file = routines.store.file
        let exists = FileManager.default.fileExists(atPath: file.path)
        NSWorkspace.shared.activateFileViewerSelecting([exists ? file : file.deletingLastPathComponent()])
    }
}

// The Settings window's own `Card` and `Row` are private to SettingsView.swift (and the
// Live View has another `Row`). These two are the same pieces, kept here so that the
// routines touch that shared file by two lines only.

/// A group of rows on one background.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One setting: what it is, what it means, and its control on the right.
private struct Row<Control: View>: View {
    private let title: String
    private let detail: String
    private let control: Control

    init(_ title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
