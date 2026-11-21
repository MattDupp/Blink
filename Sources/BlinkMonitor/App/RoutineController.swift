import SwiftUI
import BlinkCore

/// A reminder about to be shown: which routine, and which of its times.
struct RoutineBanner: Equatable {
    let routine: Routine
    /// Nil for the test reminder sent from Settings.
    let slot: RoutineSlot?
    /// It fell due while nobody was at the screen, and was kept until now.
    var kept = false
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
    /// How far back the record is kept in memory: today, and yesterday for its last time.
    private static let daysKept = 2.0
    /// How often the clock is looked at. A reminder is at most this late.
    static let tickSeconds = 20.0

    @Published private(set) var routines: [Routine]
    /// The record of the last two days, oldest first.
    @Published private(set) var events: [RoutineEvent]
    /// macOS does not let the app show banners (set by `RoutineBanners`).
    @Published var bannersRefused = false

    let store: RoutineStore
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
        someoneThere = { [weak model] in model?.someoneAtScreen() ?? true }
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

    /// Today for each routine that is on and has times.
    func days(now: Date) -> [RoutineDay] {
        routines.filter(\.isOn).map { RoutineDay(routine: $0, record: events, now: now, calendar: calendar) }
            .filter { !$0.slots.isEmpty }
    }

    /// The routines with a time waiting right now.
    func due(now: Date = Date()) -> [RoutineDay] {
        days(now: now).filter { $0.due != nil }
    }

    // MARK: - The clock

    /// Looks at the clock: writes what was dropped, and shows the reminders that are due.
    /// Called every 20 seconds, and by the tests with a time of their own.
    func tick(now: Date = Date()) {
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
                                   kept: now.timeIntervalSince(slot.due) > Self.tickSeconds * 3))
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
        if !isOn, let routine = routines.first(where: { $0.id == id }) { onSettled(routine) }
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
