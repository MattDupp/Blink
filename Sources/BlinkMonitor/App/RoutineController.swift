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
    /// The reminder of this routine is answered: its banner can go.
    var onSettled: (Routine) -> Void = { _ in }

    private let defaults: UserDefaults
    private var timer: Timer?
    private var dueShown: [String] = []
    /// Keeps `RoutineBanners` alive for as long as this is.
    private var banners: AnyObject?

    init(defaults: UserDefaults, store: RoutineStore = RoutineStore(file: RoutineStore.defaultFile), now: Date = Date()) {
        self.defaults = defaults
        self.store = store
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Routine].self, from: $0) }
        routines = Routine.merged(stored: stored ?? [])
        events = store.load(since: now.addingTimeInterval(-Self.daysKept * 86_400))
        // A timer that runs to its end marks the routine done, at the moment it ended.
        session.onDone = { [weak self] in self?.didIt($0.routine, now: $0.end) }
    }

    /// A record of its own in the temporary folder, emptied at each start: the demo, the
    /// screenshots and the tests must never write to the user's real record.
    static func scratch(defaults: UserDefaults) -> RoutineController {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-sample-routines.csv")
        try? FileManager.default.removeItem(at: file)
        return RoutineController(defaults: defaults, store: RoutineStore(file: file))
    }

    /// Connects the controller to the running app: presence from the camera, banners
    /// through the app's one `Notifier`.
    func connect(to model: MonitorModel) {
        // Under a timer nobody is looking: the other reminders are kept until it is over.
        someoneThere = { [weak model, weak self] in
            (model?.someoneAtScreen() ?? true) && self?.session.session == nil
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
        routines.filter(\.isOn).map { RoutineDay(routine: $0, record: events, now: now, calendar: calendar) }
            .filter { !$0.slots.isEmpty || $0.week != nil }
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

        let due = self.due(now: now)
        let present = someoneThere()
        for day in due {
            guard let slot = day.due,
                  policy.bannerDue(for: slot, record: events, now: now, someoneThere: present) else { continue }
            record(RoutineEvent(at: now, routine: slot.routine, slot: slot.key, action: .shown))
            // More than a tick late: it was kept for you (asleep, away, or the app was closed).
            onBanner(RoutineBanner(routine: day.routine, slot: slot,
                                   kept: now.timeIntervalSince(slot.due) > Self.tickSeconds * 3, week: day.week))
        }
        // A time can fall due, or be dropped, with nothing written (nobody is there): the
        // menu bar and the panel are told all the same.
        let keys = due.compactMap { $0.due?.id }
        if keys != dueShown {
            dueShown = keys
            objectWillChange.send()
        }
    }

    // MARK: - Done and Later

    func done(_ slot: RoutineSlot, now: Date = Date()) {
        record(RoutineEvent(at: now, routine: slot.routine, slot: slot.key, action: .done))
        settled(slot.routine, now: now)
    }

    func later(_ slot: RoutineSlot, now: Date = Date()) {
        record(RoutineEvent(at: now, routine: slot.routine, slot: slot.key, action: .later, until: policy.later(from: now)))
        settled(slot.routine, now: now)
    }

    /// "I did it", at any moment, for a routine counted by the week: it counts for the
    /// week whether or not today asked, and before the time as well as after it.
    /// (A routine with times of day is marked through its waiting time: `done(_:)`.)
    func didIt(_ id: String, now: Date = Date()) {
        guard let routine = routines.first(where: { $0.id == id }), case .timesPerWeek = routine.schedule else { return }
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
        let slots = RoutineDay(routine: routine, record: events, now: now, calendar: calendar).slots
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

    /// Replaces one time by another. Setting it to a time another reminder already has
    /// leaves one reminder at that time.
    func setTime(_ id: String, from old: TimeOfDay, to new: TimeOfDay) {
        changeTimes(id) { $0.map { $0 == old ? new : $0 } }
    }

    func setTimes(_ id: String, _ times: [TimeOfDay]) {
        changeTimes(id) { _ in times }
    }

    /// Adds a time: an hour after the last one, or the first free hour of the day.
    func addTime(_ id: String) {
        changeTimes(id) { times in
            let hours = Set(times.map(\.hour))
            let after = (times.last?.hour ?? 7) + 1
            guard let hour = (Array(after..<24) + Array(0..<after)).first(where: { !hours.contains($0) }) else { return times }
            return times + [TimeOfDay(hour: hour)]
        }
    }

    func removeTime(_ id: String, _ time: TimeOfDay) {
        changeTimes(id) { times in times.count > 1 ? times.filter { $0 != time } : times }
    }

    /// Shows the reminder now, as it will look. Its buttons do nothing.
    func sendTest(_ id: String) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        onBanner(RoutineBanner(routine: routine, slot: nil))
    }

    private func changeTimes(_ id: String, _ change: ([TimeOfDay]) -> [TimeOfDay]) {
        self.change(id) { routine in
            guard case .timesOfDay(_, let weekdays) = routine.schedule else { return }
            routine.schedule = .timesOfDay(times: Array(Set(change(routine.times))).sorted(), weekdays: weekdays)
        }
    }

    private func change(_ id: String, _ change: (inout Routine) -> Void) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        change(&routines[index])
        if let data = try? JSONEncoder().encode(routines) { defaults.set(data, forKey: Self.key) }
    }
}

extension MonitorModel {

    /// Whether somebody is at the screen, as far as the app can tell.
    ///
    /// While the camera is read, it is the face being in view. While it is not (a pause,
    /// the camera refused, a closed lid on an external screen), the app cannot know: a
    /// screen that is awake is taken as somebody being there, so that a pause of the
    /// camera does not silence the routines.
    func someoneAtScreen(now: Date = Date()) -> Bool {
        status(now: now).isCameraOn ? live.faceFound : !asleep
    }
}
