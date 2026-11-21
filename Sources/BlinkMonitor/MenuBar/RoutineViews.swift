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
        let days = routines.days(now: now)
        if !days.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Routine")
                ForEach(days, id: \.routine.id) { day in
                    RoutineRow(day: day, done: { routines.done($0) }, later: { routines.later($0) },
                               laterMinutes: routines.policy.laterMinutes)
                }
            }
            .padding(16)
            Divider()
        }
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
            ForEach(routines.routines.filter { !$0.times.isEmpty }) { routine in
                card(for: routine)
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
