import SwiftUI
import BlinkCore

/// A reminder about to be shown: which routine, and which of its times.
struct RoutineBanner: Equatable {
    let routine: Routine
    /// Nil for the test reminder sent from Settings.
    let slot: RoutineSlot?
    /// It fell due while nobody was at the screen, and was kept until now.
    var kept = false
    /// For a routine counted by the week: where the week stands.
    var week: RoutineWeek?
}

/// Your routines: which ones are on, what happened to today's times, and the moment to
/// remind you.
///
/// It stores two things only: the routines (with the other settings) and the record (a
/// file, see `RoutineStore`). "What is due now" is NOT stored: `RoutineDay` works it out
/// from those two and the clock each time it is asked, here as everywhere.
///
/// It knows nothing about macOS notifications. It says "show this" through `onBanner`;
/// `RoutineBanners` turns that into a banner. That keeps this class testable by hand:
/// a test gives it a clock, says whether somebody is there, and reads what it asked for.
@MainActor
final class RoutineController: ObservableObject {

    private static let key = "routines"
    private static let quietKey = "routinesQuietDay"
    /// How many routines of your own can be kept. Enough for a day's habits; few enough
    /// that the Settings tab stays a list one can read.
    static let mostOwn = 8
    /// How far back the record is kept in memory: the whole of this week for the routines
    /// counted by the week, and yesterday when yesterday was last week's Sunday.
    private static let daysKept = 9.0
    /// How often the clock is looked at. A reminder is at most this late.
    static let tickSeconds = 20.0

    @Published private(set) var routines: [Routine]
    /// The record of the last nine days, oldest first.
    @Published private(set) var events: [RoutineEvent]
    /// macOS does not let the app show banners (set by `RoutineBanners`).
    @Published var bannersRefused = false

    let store: RoutineStore
    /// The timer of a routine that has one (see `RoutineSessionController`).
    let session = RoutineSessionController()
    var policy = RoutinePolicy()
    /// The calendar the times are read with. The live one: it follows a change of time zone.
    var calendar = Calendar.autoupdatingCurrent

    /// Whether somebody is at the screen right now (see `MonitorModel.someoneAtScreen`).
    var someoneThere: () -> Bool = { true }
    /// Show this reminder.
    var onBanner: (RoutineBanner) -> Void = { _ in }
    /// The app's one gate for banners (`BannerGate`), set when the app connects it. Until
    /// then no banner is shown (the tests that want banners say `.always`).
    var turns = BannerTurns.never
    /// The reminder of this routine is answered: its banner can go.
    var onSettled: (Routine) -> Void = { _ in }

    private let defaults: UserDefaults
    private var timer: Timer?
    private var dueShown: [String] = []
    /// The routines that had a time waiting at the last look.
    private var dueWasShown: Set<String> = []
    /// The count of each routine "at the screen", by routine id (see `ScreenCount`).
    /// In memory only: a relaunch starts them from zero.
    private var counts: [String: ScreenCount] = [:]
    /// "Quiet for today" was chosen on this day (`RoutineWeek.key`). Stored, so that a
    /// relaunch does not undo it; it ends by itself when the day's name changes.
    @Published private var quietDay: String?
    /// The panel shows every routine, not only what waits and what is next.
    @Published var showsAll = false
    /// The weekly routines whose days and buttons are open in the panel. With nothing
    /// due, a weekly routine is one line; a click opens it.
    @Published var openWeeks: Set<String> = []
    /// The routine whose editor is open in Settings: one at a time. Every card was a full
    /// editor, always open, and two routines filled the screen.
    @Published var openCard: String?
    /// Keeps `RoutineBanners` alive for as long as this is.
    private var banners: AnyObject?

    init(defaults: UserDefaults, store: RoutineStore, now: Date = Date()) {
        self.defaults = defaults
        self.store = store
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Routine].self, from: $0) }
        routines = Routine.merged(stored: stored ?? [])
        events = store.load(since: now.addingTimeInterval(-Self.daysKept * 86_400))
        quietDay = defaults.string(forKey: Self.quietKey)
        // A timer that runs to its end marks the routine done, at the moment it ended.
        session.onDone = { [weak self] in self?.didIt($0.routine, now: $0.end) }
    }

    /// Connects the controller to the running app: presence from the camera, banners
    /// through the app's one `Notifier`.
    func connect(to model: MonitorModel) {
        // Under a timer nobody is looking: the other reminders are kept until it is over.
        // During a blink break you are busy blinking: a banner would cover the exercise.
        someoneThere = { [weak model, weak self] in
            (model?.someoneAtScreen() ?? true) && self?.session.session == nil && model?.blinkBreak.exercise == nil
        }
        // The timer pauses the camera for its length: covered eyes must not be read as a
        // low blink rate. A pause you chose yourself is left exactly as it is.
        session.pauseCamera = { [weak model] end in
            guard let model, !model.isPaused else { return false }
            model.pause(until: end)
            return true
        }
        session.resumeCamera = { [weak model] end in
            if let model, model.pause == .paused(until: end) { model.resume() }
        }
        banners = RoutineBanners(notifier: model.reminders.notifier, routines: self)
        turns = model.reminders.turns
    }

    /// Starts looking at the clock.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        // `.common`: it also fires while a menu or the panel is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    // MARK: - What the windows ask

    /// Today for each routine that is on and has something to show: times today, or a
    /// week being counted (which is shown on its quiet days too).
    func days(now: Date) -> [RoutineDay] {
        routines.filter(\.isOn).map {
            RoutineDay(routine: $0, record: events, now: now, calendar: calendar, screen: counts[$0.id])
        }
        .filter { !$0.slots.isEmpty || $0.week != nil || $0.screen != nil }
    }

    /// No routine banner until midnight: chosen in the panel.
    func isQuiet(now: Date = Date()) -> Bool {
        quietDay == RoutineWeek.key(of: now, calendar: calendar)
    }

    /// "Quiet for today", and back. Quiet silences the banners only: the mark in the menu
    /// bar and the panel go on showing what waits.
    func setQuiet(_ quiet: Bool, now: Date = Date()) {
        quietDay = quiet ? RoutineWeek.key(of: now, calendar: calendar) : nil
        defaults.set(quietDay, forKey: Self.quietKey)
        if quiet { routines.forEach(onSettled) }       // the banners on screen can go
    }

    /// Erases the routine log, on disk and in memory. What was done today and this week
    /// is worked out from it, so those marks start again; the routines themselves stay.
    func eraseRecord() {
        guard store.erase() else { return }
        events = []
        routines.forEach(onSettled)
    }

    /// The routines with a time waiting right now.
    func due(now: Date = Date()) -> [RoutineDay] {
        days(now: now).filter { $0.due != nil }
    }

    // MARK: - The clock

    /// Looks at the clock: writes what was dropped, and shows the reminders that are due.
    /// Called every 20 seconds, and by the tests with a time of their own.
    func tick(now: Date = Date()) {
        session.check(now: now)     // a timer whose end passed while the Mac slept
        for miss in RoutineDay.unrecordedMisses(routines: routines, record: events, now: now, calendar: calendar) {
            record(miss)
        }
        let oldest = now.addingTimeInterval(-Self.daysKept * 86_400)
        if let first = events.first, first.at < oldest { events.removeAll { $0.at < oldest } }

        let present = someoneThere()
        // The routines "at the screen" are told what this look saw. Under a timer the
        // count stands still: eyes covered is neither at the screen nor away.
        for routine in routines where routine.isOn {
            guard let minutes = routine.screenMinutes else { continue }
            counts[routine.id, default: ScreenCount()].advance(to: now, present: present, holding: session.session != nil,
                                                               minutes: minutes, calendar: calendar)
        }

        let due = self.due(now: now)
        // ONE banner a look at most, and only when there is room (`RoutinePolicy.mayShow`):
        // with several routines due together they come one by one, never as a burst.
        if !isQuiet(now: now), policy.mayShow(record: events, now: now) {
            turns.take(.routine, now) {
                guard let day = policy.order(due, record: events).first(where: {
                    guard let slot = $0.due else { return false }
                    return policy.bannerDue(for: slot, record: events, now: now, someoneThere: present, repeats: $0.screen == nil)
                }), let slot = day.due else { return false }
                record(RoutineEvent(at: now, routine: slot.routine, slot: slot.key, action: .shown))
                // More than a tick late: it was kept for you (asleep, away, held back, or the app was closed).
                onBanner(RoutineBanner(routine: day.routine, slot: slot,
                                       kept: now.timeIntervalSince(slot.due) > Self.tickSeconds * 3, week: day.week))
                return true
            }
        }
        // A time can fall due, or be dropped, with nothing written (nobody is there): the
        // menu bar and the panel are told all the same.
        let keys = due.compactMap { $0.due?.id }
        if keys != dueShown {
            // A routine that was waiting and no longer is (its time was dropped, or the
            // day ended): its banner goes too. Yesterday's stayed in Notification Centre,
            // and its Done did nothing.
            let waiting = Set(due.map(\.routine.id))
            for routine in routines where dueWasShown.contains(routine.id) && !waiting.contains(routine.id) { onSettled(routine) }
            dueWasShown = waiting
            dueShown = keys
            // Ids only: a routine's name is the user's own words, and stays out of the log.
            Log.app.notice("Routines waiting: \(due.map(\.routine.id).joined(separator: " "), privacy: .public)")
            objectWillChange.send()
        }
    }

    // MARK: - Done and Later

    func done(_ slot: RoutineSlot, now: Date = Date()) {
        record(RoutineEvent(at: now, routine: slot.routine, slot: slot.key, action: .done))
        counts[slot.routine]?.restart()     // "at the screen": the count starts again from here
        settled(slot.routine, now: now)
    }

    func later(_ slot: RoutineSlot, now: Date = Date()) {
        record(RoutineEvent(at: now, routine: slot.routine, slot: slot.key, action: .later, until: policy.later(from: now)))
        settled(slot.routine, now: now)
    }

    /// "I did it", at any moment, for a routine counted by the week: it counts for the
    /// week whether or not today asked, and before the time as well as after it.
    /// For the other kinds (this is how a timer that ran to its end marks them): the time
    /// that waits, or was put off, is done; with none, a count "at the screen" starts again.
    func didIt(_ id: String, now: Date = Date()) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        guard case .timesPerWeek = routine.schedule else {
            let day = RoutineDay(routine: routine, record: events, now: now, calendar: calendar, screen: counts[id])
            if let slot = day.due ?? day.putOff { done(slot, now: now) } else { counts[id]?.restart() }
            return
        }
        record(RoutineEvent(at: now, routine: id, slot: RoutineWeek.key(of: now, calendar: calendar), action: .done))
        settled(id, now: now)
    }

    /// Takes back the latest "I did it" of today, pressed by mistake.
    func undo(_ id: String, now: Date = Date()) {
        guard let day = days(now: now).first(where: { $0.routine.id == id }), let today = day.week?.today,
              today.done > 0 else { return }
        record(RoutineEvent(at: now, routine: id, slot: today.key, action: .undone))
        dueShown = due(now: now).compactMap { $0.due?.id }
    }

    /// Starts the routine's timer, if it has one and none is running.
    func startSession(_ id: String, now: Date = Date()) {
        guard let routine = routines.first(where: { $0.id == id }), session.start(routine, now: now) else { return }
        record(RoutineEvent(at: now, routine: id, slot: RoutineWeek.key(of: now, calendar: calendar), action: .started))
        onSettled(routine)      // the banner is answered: it can go
    }

    /// A banner's button was pressed. The banner names the time by its key, and can be
    /// answered late: only a time that is still waiting is touched.
    func answer(routine id: String, slot key: String, done: Bool, now: Date = Date()) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        let slots = RoutineDay(routine: routine, record: events, now: now, calendar: calendar, screen: counts[id]).slots
        guard let slot = slots.first(where: { $0.key == key }), slot.status == .due else { return }
        if done { self.done(slot, now: now) } else { later(slot, now: now) }
    }

    private func settled(_ id: String, now: Date) {
        if let routine = routines.first(where: { $0.id == id }) { onSettled(routine) }
        dueShown = due(now: now).compactMap { $0.due?.id }
    }

    /// Adds a line to the record, in memory and on disk.
    func record(_ event: RoutineEvent) {
        events.append(event)
        store.append(event)
    }

    // MARK: - Settings

    func setOn(_ id: String, _ isOn: Bool, now: Date = Date()) {
        change(id) {
            $0.isOn = isOn
            // The times already past today are not asked for (see `Routine.onSince`).
            $0.onSince = isOn ? now : nil
        }
        counts[id] = nil        // "at the screen": switched on again, it counts from zero
        if !isOn, let routine = routines.first(where: { $0.id == id }) {
            onSettled(routine)
            if session.session?.routine == id { session.stop() }
        }
    }

    // A routine counted by the week: its count, its preferred days, its time.

    func setWeekCount(_ id: String, _ count: Int) {
        changeWeek(id) { _, weekdays, time in (min(max(count, 1), 7), weekdays, time) }
    }

    /// `weekday`: 1 = Sunday ... 7 = Saturday. The last preferred day cannot be removed.
    func setWeekday(_ id: String, _ weekday: Int, preferred: Bool) {
        changeWeek(id) { count, weekdays, time in
            var days = weekdays
            if preferred { days.insert(weekday) } else if days.count > 1 { days.remove(weekday) }
            return (count, days, time)
        }
    }

    func setWeekTime(_ id: String, _ time: TimeOfDay) {
        changeWeek(id) { count, weekdays, _ in (count, weekdays, time) }
    }

    // MARK: Routines of your own

    private var ownCount: Int { routines.filter { !$0.isBuiltIn }.count }
    var canAdd: Bool { ownCount < Self.mostOwn }

    /// Adds a routine of your own from a starting point, switched on. Answers its id.
    @discardableResult
    func add(_ template: RoutineTemplate, now: Date = Date()) -> String? {
        var routine = Routine.made(from: template, now: now)
        while routines.contains(where: { $0.id == routine.id }) { routine = Routine.made(from: template, now: now) }
        return add(routine) ? routine.id : nil
    }

    /// Adds this routine as it is. False when its id is taken, or the list is full.
    @discardableResult
    func add(_ routine: Routine) -> Bool {
        guard canAdd, !routines.contains(where: { $0.id == routine.id }) else { return false }
        var routine = routine
        routine.name = Routine.typedName(routine.name)
        routines.append(routine)
        save()
        openCard = routine.id       // a new routine opens, ready to be named and timed
        return true
    }

    /// Puts a count in place, as if that time at the screen had been watched: for the
    /// screenshots, which have no minutes to wait.
    func show(count: ScreenCount, of id: String) {
        counts[id] = count
        objectWillChange.send()
    }

    /// Deletes a routine of your own. A built-in one can only be switched off.
    ///
    /// ITS LINES STAY IN THE RECORD. `routines.csv` only ever grows: no line is rewritten
    /// or removed, here as elsewhere. The lines name an id that is never given again, so
    /// they disturb nothing; they are what was done, and stay yours to read.
    func remove(_ id: String) {
        guard let routine = routines.first(where: { $0.id == id }), !routine.isBuiltIn else { return }
        onSettled(routine)
        if session.session?.routine == id { session.stop() }
        routines.removeAll { $0.id == id }
        counts[id] = nil
        save()
    }

    /// A sound with this routine's reminder, or silence (how every routine starts).
    func setSound(_ id: String, _ on: Bool) {
        change(id) { $0.soundOn = on ? true : nil }
    }

    /// Takes a built-in routine out of Settings: switched off, and no longer listed. It
    /// keeps its times, and "Add a Routine" brings it back.
    func hide(_ id: String) {
        guard routines.contains(where: { $0.id == id && $0.isBuiltIn }) else { return }
        setOn(id, false)
        change(id) { $0.hidden = true }
        if openCard == id { openCard = nil }
    }

    func unhide(_ id: String) {
        change(id) { $0.hidden = nil }
        openCard = id
    }

    /// The built-in routines that were taken out of Settings.
    var hiddenBuiltIn: [Routine] { routines.filter { $0.isBuiltIn && $0.isHidden } }

    /// A routine at times of day asks on these days of the week only (1 = Sunday).
    /// All seven is "every day"; the last day cannot be taken away.
    func setDay(_ id: String, _ weekday: Int, on: Bool) {
        change(id) { routine in
            guard case .timesOfDay(let times, let weekdays) = routine.schedule else { return }
            var days = weekdays ?? Set(1...7)
            if on { days.insert(weekday) } else if days.count > 1 { days.remove(weekday) }
            routine.schedule = .timesOfDay(times: times, weekdays: days.count == 7 ? nil : days)
        }
    }

    /// Renames a routine of your own. Only the name changes: the record knows it by its id.
    func rename(_ id: String, _ name: String) {
        change(id) { if !$0.isBuiltIn { $0.name = Routine.typedName(name) } }
    }

    func setSymbol(_ id: String, _ symbol: String) {
        change(id) { if !$0.isBuiltIn, Routine.symbols.contains(symbol) { $0.symbol = symbol } }
    }

    /// Gives a routine of your own another kind of schedule, at that kind's starting
    /// point. What waited under the old kind no longer waits: its banner goes, and the
    /// new schedule asks from now on (as when a routine is switched on).
    ///
    /// While the Settings window is open, each kind's schedule is remembered: looking at
    /// "At the screen" and coming back no longer throws away every time that was typed.
    func setKind(_ id: String, _ kind: RoutineSchedule.Kind, now: Date = Date()) {
        guard let routine = routines.first(where: { $0.id == id }), !routine.isBuiltIn, routine.schedule.kind != kind else { return }
        onSettled(routine)
        counts[id] = nil
        var rows = drafts[id]
        rememberedSchedules[id, default: [:]][routine.schedule.kind] = (routine.schedule, rows)
        let remembered = rememberedSchedules[id]?[kind]
        rows = remembered?.rows
        drafts[id] = rows
        change(id) {
            $0.schedule = remembered?.schedule ?? RoutineSchedule.starting(kind)
            if $0.isOn { $0.onSince = now }
        }
    }

    // MARK: Times, while they are being edited

    /// The times of a routine as the Settings window shows them: in the order they were
    /// entered, a double included, for as long as the window is open.
    ///
    /// WHY NOT THE STORED TIMES. Those are sorted and without doubles, which is what the
    /// reminders need. Shown as they are stored, the rows changed place under the cursor
    /// (stepping 08:00 past 13:00 moved the row being edited), and stepping one time onto
    /// another made a row vanish. So the rows are kept apart while they are edited, and
    /// sorted and merged when the window closes (`endEditing`).
    func shownTimes(of routine: Routine) -> [TimeOfDay] {
        drafts[routine.id] ?? routine.times
    }

    /// The row that already has this row's time, if any: said beside it.
    func double(of index: Int, in routine: Routine) -> Int? {
        let rows = shownTimes(of: routine)
        guard rows.indices.contains(index) else { return nil }
        return rows.indices.first { $0 != index && rows[$0] == rows[index] }
    }

    func setTime(_ id: String, at index: Int, to new: TimeOfDay) {
        editRows(id) { if $0.indices.contains(index) { $0[index] = new } }
    }

    /// Adds a row: an hour after the last one, or the first free hour of the day.
    func addTimeRow(_ id: String) {
        editRows(id) { rows in
            let hours = Set(rows.map(\.hour))
            let after = (rows.last?.hour ?? 7) + 1
            if let hour = (Array(after..<24) + Array(0..<after)).first(where: { !hours.contains($0) }) {
                rows.append(TimeOfDay(hour: hour))
            }
        }
    }

    func removeTime(_ id: String, at index: Int) {
        editRows(id) { if $0.count > 1, $0.indices.contains(index) { $0.remove(at: index) } }
    }

    /// The Settings window closed: the rows are the stored times again, sorted and merged.
    func endEditing() {
        if !drafts.isEmpty { drafts = [:] }
        rememberedSchedules = [:]
    }

    private func editRows(_ id: String, _ edit: (inout [TimeOfDay]) -> Void) {
        guard let routine = routines.first(where: { $0.id == id }), case .timesOfDay = routine.schedule else { return }
        var rows = shownTimes(of: routine)
        edit(&rows)
        drafts[id] = rows
        changeTimes(id, keepRows: true) { _ in rows }
    }

    /// "Every so many minutes at the screen": how many.
    func setScreenMinutes(_ id: String, _ minutes: Int) {
        change(id) { routine in
            guard routine.screenMinutes != nil else { return }
            let range = RoutineSchedule.screenMinutes
            routine.schedule = .everyMinutesAtScreen(minutes: min(max(minutes, range.lowerBound), range.upperBound))
        }
    }

    /// Gives a routine a timer (of ten minutes, to be set), or takes it away.
    func setTimer(_ id: String, _ hasTimer: Bool) {
        if !hasTimer, session.session?.routine == id { session.stop() }
        change(id) { $0.sessionMinutes = hasTimer ? ($0.sessionMinutes ?? 10) : nil }
    }

    /// The length of the routine's timer, for a routine that has one.
    func setSessionMinutes(_ id: String, _ minutes: Int) {
        change(id) { routine in
            if routine.sessionMinutes != nil { routine.sessionMinutes = min(max(minutes, 1), 60) }
        }
    }

    private func changeWeek(_ id: String, _ change: (Int, Set<Int>, TimeOfDay) -> (Int, Set<Int>, TimeOfDay)) {
        self.change(id) { routine in
            guard case .timesPerWeek(let count, let weekdays, let time) = routine.schedule else { return }
            let new = change(count, weekdays, time)
            routine.schedule = .timesPerWeek(count: new.0, weekdays: new.1, time: new.2)
        }
    }

    /// The rows being edited, and each kind's schedule as it was left (see `setKind`).
    @Published private(set) var drafts: [String: [TimeOfDay]] = [:]
    private var rememberedSchedules: [String: [RoutineSchedule.Kind: (schedule: RoutineSchedule, rows: [TimeOfDay]?)]] = [:]

    func setTimes(_ id: String, _ times: [TimeOfDay]) {
        changeTimes(id) { _ in times }
    }

    /// Shows the reminder now, as it will look. Its buttons do nothing.
    func sendTest(_ id: String) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        onBanner(RoutineBanner(routine: routine, slot: nil))
    }

    /// `keepRows`: the change comes from the rows being edited; any other change of the
    /// times makes the rows follow what is stored.
    private func changeTimes(_ id: String, keepRows: Bool = false, _ change: ([TimeOfDay]) -> [TimeOfDay]) {
        if !keepRows, drafts[id] != nil { drafts[id] = nil }
        self.change(id) { routine in
            guard case .timesOfDay(_, let weekdays) = routine.schedule else { return }
            routine.schedule = .timesOfDay(times: Array(Set(change(routine.times))).sorted(), weekdays: weekdays)
        }
    }

    private func change(_ id: String, _ change: (inout Routine) -> Void) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        change(&routines[index])
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(routines) { defaults.set(data, forKey: Self.key) }
    }
}
