import SwiftUI
import AppKit
import BlinkCore

// MARK: - In the panel

/// Today's routines in the panel: each time of the day and where it stands, and Done and
/// Later while one is waiting. Draws nothing at all when no routine is switched on, so the
/// panel of someone who does not use routines is unchanged.
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
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Routine")
                ForEach(days, id: \.routine.id) { day in
                    if let week = day.week {
                        WeekRow(day: day, week: week, running: session.session?.routine == day.routine.id ? session.session : nil,
                                calendar: routines.calendar, laterMinutes: routines.policy.laterMinutes,
                                actions: WeekRow.Actions(
                                    didIt: { routines.didIt(day.routine.id) }, undo: { routines.undo(day.routine.id) },
                                    later: { routines.later($0) }, start: { routines.startSession(day.routine.id) },
                                    stop: { session.stop() }))
                    } else {
                        RoutineRow(day: day, done: { routines.done($0) }, later: { routines.later($0) },
                                   laterMinutes: routines.policy.laterMinutes)
                    }
                }
            }
            .padding(16)
            Divider()
        }
    }
}

/// A routine counted by the week: how far the week is, its seven days, and what can be
/// done now. "I Did It" is always there: doing it early, or on a day that did not ask,
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
    let calendar: Calendar
    let laterMinutes: Int
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: day.routine.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                Text(day.routine.name)
                Spacer(minLength: 8)
                Text("\(week.done) of \(week.target) this week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                            Button("Later") { actions.later(slot) }
                                .help("Remind me again in \(laterMinutes) minutes")
                        }
                        if let minutes = day.routine.sessionMinutes {
                            Button("Start Timer") { actions.start() }
                                .help("\(minutes) minutes. The camera is paused meanwhile, a sound marks the end, and it is marked done.")
                        }
                        Button("I Did It") { actions.didIt() }
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
        if let slot = day.putOff, case .later(let until) = slot.status { return "Put off until \(Format.time(until))" }
        if week.today.done > 1 { return "Done \(week.today.done) times today" }
        if week.today.done == 1 { return week.isReached ? "Done today. That is the week's count." : "Done today" }
        if week.isReached { return "Done for this week" }
        if let slot = day.next { return "Today at \(Format.time(slot.due))" }
        if let next = week.nextAsk { return "Next on \(calendar.weekdaySymbols[next.weekday - 1])" }
        return "Nothing more is asked this week"
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
        return place == .past ? "not done" : "nothing asked"
    }
}

/// One routine: its name, what comes next, its times, and the two buttons when needed.
private struct RoutineRow: View {
    let day: RoutineDay
    let done: (RoutineSlot) -> Void
    let later: (RoutineSlot) -> Void
    let laterMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: day.routine.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                Text(day.routine.name)
                Spacer(minLength: 8)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The times, side by side. With too many to fit, the summary above says enough.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(day.slots) { TimeChip(slot: $0) }
                }
                EmptyView()
            }
            if let slot = day.due {
                waiting("\(Format.time(slot.due)) is waiting", slot: slot, offerLater: true)
            } else if let slot = day.putOff, case .later(let until) = slot.status {
                waiting("\(Format.time(slot.due)) put off until \(Format.time(until))", slot: slot, offerLater: false)
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
                Button("Later") { later(slot) }
                    .help("Remind me again in \(laterMinutes) minutes")
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
        case .later: return "put off"
        case .done: return "done"
        case .missed: return "not done"
        case .notAsked: return "not asked for today"
        }
    }
}

// MARK: - In Settings

/// The Routines tab: each routine with its switch and its times, and a test reminder.
///
/// The wording is deliberate: the app reminds you of a routine you chose. It gives no
/// advice on what to do for your eyes or how often.
struct RoutineSettings: View {
    @ObservedObject var routines: RoutineController
    var moment = Moment()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(routines.routines) { routine in
                // One card per kind of schedule. (A kind with no screen yet is not listed.)
                switch routine.schedule {
                case .timesOfDay: card(for: routine)
                case .timesPerWeek(let count, let weekdays, let time):
                    weekCard(for: routine, count: count, weekdays: weekdays, time: time)
                case .everyMinutesAtScreen: EmptyView()
                }
            }
            Card {
                Row("Record", detail: "One line each time a reminder is shown, done, put off or left. It stays on this Mac. Any spreadsheet opens it.") {
                    Button("Show in Finder") { showRecord() }
                }
            }
            if routines.bannersRefused && routines.routines.contains(where: \.isOn) {
                Label("Notifications are off for Blink Monitor in System Settings. The menu bar and the panel still show what is waiting.",
                      systemImage: "bell.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Blink Monitor reminds you of a routine that you, or your eye-care professional, chose. It does not say what to use or how often. "
                 + "A reminder is silent and waits until you are at the screen. It comes once more after \(routines.policy.repeatAfterMinutes) minutes, "
                 + "then a dot in the menu bar waits with it until its next time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(for routine: Routine) -> some View {
        Card {
            Row(routine.name, detail: "A reminder at each of the times below, with Done and Later.") {
                Toggle(routine.name, isOn: Binding(get: { routine.isOn }, set: { routines.setOn(routine.id, $0) }))
            }
            // By position, not by time: a row keeps its place (and the keyboard) while its time is typed.
            ForEach(Array(routine.times.enumerated()), id: \.offset) { index, time in
                Divider()
                timeRow(routine, index: index, time: time)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Add a Time") { routines.addTime(routine.id) }
                    .disabled(routine.times.count >= 12)
                Spacer(minLength: 12)
                Button("Send a Test Reminder") { routines.sendTest(routine.id) }
                    .help("Shows the reminder now. Its buttons do nothing on a test.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// A routine counted by the week: its count, the days it asks first, its time, and
    /// the length of its timer when it has one.
    private func weekCard(for routine: Routine, count: Int, weekdays: Set<Int>, time: TimeOfDay) -> some View {
        let calendar = routines.calendar
        // The days in the order of this Mac's week: Monday first, or Sunday.
        let ordered = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return Card {
            Row(routine.name, detail: "A reminder on your days, until the week's count is reached. Mark it done at any time from the menu-bar panel.") {
                Toggle(routine.name, isOn: Binding(get: { routine.isOn }, set: { routines.setOn(routine.id, $0) }))
            }
            Divider()
            Row("Times a week", detail: "A count to reach, not appointments. Miss a day, and the next day asks instead.") {
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
                HStack(spacing: 6) {
                    ForEach(ordered, id: \.self) { weekday in
                        let chosen = weekdays.contains(weekday)
                        // A plain button drawn by hand: a system toggle button barely
                        // shows which days are chosen when the window is not in front.
                        Button { routines.setWeekday(routine.id, weekday, preferred: !chosen) } label: {
                            Text(calendar.shortWeekdaySymbols[weekday - 1])
                                .font(.callout.weight(chosen ? .semibold : .regular))
                                .foregroundStyle(chosen ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(chosen ? Color.accentColor : Color.primary.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                        .accessibilityValue(chosen ? "chosen" : "not chosen")
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                Text("The days it asks first. One day at least.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if let minutes = routine.sessionMinutes {
                Divider()
                Row("Timer", detail: "Set this to the length its own instructions give. While it runs the camera is paused, "
                    + "the Mac stays awake, and a sound marks the end. Then it is marked done.") {
                    HStack(spacing: 6) {
                        Text("\(minutes) min").monospacedDigit().fixedSize()
                        Stepper("Length of the timer, in minutes",
                                value: Binding(get: { minutes }, set: { routines.setSessionMinutes(routine.id, $0) }), in: 1...60)
                            .accessibilityValue("\(minutes)")
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Spacer(minLength: 12)
                Button("Send a Test Reminder") { routines.sendTest(routine.id) }
                    .help("Shows the reminder now. Its buttons do nothing on a test.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func timeRow(_ routine: Routine, index: Int, time: TimeOfDay) -> some View {
        HStack(spacing: 12) {
            Text("Reminder \(index + 1)")
                .foregroundStyle(routine.isOn ? .primary : .secondary)
            Spacer(minLength: 12)
            DatePicker("Time of reminder \(index + 1)", selection: Binding(
                get: { Self.date(of: time, on: moment.now) },
                set: { routines.setTime(routine.id, from: time, to: Self.time(of: $0)) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
            Button { routines.removeTime(routine.id, time) } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(routine.times.count <= 1)
            .help("Remove this time")
            .accessibilityLabel("Remove reminder \(index + 1)")
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
