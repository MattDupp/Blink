import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import BlinkCore

// The app's state is split by subject. Each of these small classes owns one subject,
// publishes what the windows show about it, and knows nothing about the others;
// `MonitorModel` connects them.

// MARK: - History

/// The minutes of the last days: loaded once from disk, extended as minutes end.
@MainActor
final class HistoryController: ObservableObject {

    /// How far back the app looks (the history window shows a week).
    static let daysKept = 8

    /// Finished minutes, oldest first.
    @Published private(set) var minutes: [MinuteRecord] = []
    /// The minute being filled.
    @Published private(set) var currentMinute: MinuteRecord?

    let store: HistoryStore

    init(store: HistoryStore = HistoryStore(file: HistoryStore.defaultFile)) {
        self.store = store
    }

    func load(now: Date = Date()) {
        minutes = store.load(since: now.addingTimeInterval(-Double(Self.daysKept) * 86_400))
    }

    func minuteEnded(_ minute: MinuteRecord, now: Date = Date()) {
        // A minute in which the eyes were never read (you were away) is not a record.
        guard minute.observedSeconds >= 1 else { return }
        minutes.append(minute)
        store.append(minute)
        let oldest = now.addingTimeInterval(-Double(Self.daysKept) * 86_400)
        if let first = minutes.first, first.start < oldest {
            minutes.removeAll { $0.start < oldest }
        }
    }

    func update(current: MinuteRecord?) {
        // Published about once a second, not per frame: the panel does not need more.
        if let current, current.start != currentMinute?.start
            || current.blinks != currentMinute?.blinks
            || abs(current.observedSeconds - (currentMinute?.observedSeconds ?? 0)) >= 1 {
            currentMinute = current
        }
    }

    /// The records of one calendar day, including the minute being filled.
    func records(on day: Date, calendar: Calendar = .current) -> [MinuteRecord] {
        var records = minutes.filter { calendar.isDate($0.start, inSameDayAs: day) }
        if let currentMinute, calendar.isDate(currentMinute.start, inSameDayAs: day) { records.append(currentMinute) }
        return records
    }

    func summary(of day: Date, threshold: Double) -> DaySummary {
        DaySummary(records: records(on: day), threshold: threshold)
    }

    /// One day cut into its 24 hours (index 0 = midnight to 1 am).
    func hours(of day: Date, threshold: Double, calendar: Calendar = .current) -> [DaySummary] {
        var byHour = [[MinuteRecord]](repeating: [], count: 24)
        for record in records(on: day, calendar: calendar) {
            byHour[calendar.component(.hour, from: record.start)].append(record)
        }
        return byHour.map { DaySummary(records: $0, threshold: threshold) }
    }

    /// Made-up minutes for the last week, the same at every run: what the windows look
    /// like after a week of use, for the screenshots (`--snapshots`). Never written to disk.
    func loadSample(now: Date, low: Bool = false, calendar: Calendar = .current) {
        var seed: UInt64 = 20_261_120
        func random() -> Double {                 // a small fixed generator: same data every time
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var sample: [MinuteRecord] = []
        let today = calendar.startOfDay(for: now)
        for back in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  !calendar.isDateInWeekend(day) else { continue }        // a working week
            let dayLevel = [15.5, 13.0, 14.5, 11.5, 14.0, 16.0, 13.5][back % 7]
            for hour in [9, 10, 11, 13, 14, 15, 16, 17] {
                for minute in 0..<60 {
                    guard let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                          start < now, random() > 0.12 else { continue }      // away now and then
                    // Deep concentration after lunch: fewer blinks. (`low`: it lasts until now.)
                    let deep = hour == 14 || hour == 15 || (low && hour >= 16)
                    let focus = deep ? 0.58 : (hour == 10 ? 0.85 : 1.0)
                    let rate = max(2, dayLevel * focus + (random() - 0.5) * 9)
                    let watched = 48 + random() * 12
                    sample.append(MinuteRecord(start: start, observedSeconds: watched,
                                               blinks: Int((rate * watched / 60).rounded())))
                }
            }
        }
        minutes = sample
        currentMinute = nil
    }

    /// The last `count` days, oldest first, today last.
    func lastDays(_ count: Int, threshold: Double, now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, summary: DaySummary)] {
        (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)).map {
                ($0, summary(of: $0, threshold: threshold))
            }
        }
    }
}

// MARK: - Reminders

/// The reminder settings, the "you blink too little" state, and the notifications.
@MainActor
final class ReminderController: ObservableObject {

    /// "Blinking too little" starts under this many blinks a minute. People at rest blink
    /// roughly 15 to 20 times a minute, and far less when staring at a screen; 10 is a
    /// starting point for you to adjust, not a medical limit.
    @Published var threshold: Int {
        didSet {
            UserDefaults.standard.set(threshold, forKey: "threshold")
            onChange?()
        }
    }
    @Published private(set) var remindersOn: Bool
    @Published private(set) var notificationsRefused = false
    /// Your rate over the last 3 minutes while it is under the threshold, else nil.
    @Published private(set) var lowRate: Double?
    @Published private(set) var snoozedUntil: Date?

    /// Called when something the menu bar shows has changed.
    var onChange: (() -> Void)?

    private var policy = ReminderPolicy()
    private let notifier = Notifier()

    init() {
        let defaults = UserDefaults.standard
        threshold = defaults.object(forKey: "threshold") as? Int ?? 10
        remindersOn = defaults.object(forKey: "remindersOn") as? Bool ?? true
    }

    /// A fixed state for the screenshots (`--snapshots`); nothing is saved.
    func loadSample(lowRate: Double?, snoozedUntil: Date? = nil) {
        self.lowRate = lowRate
        self.snoozedUntil = snoozedUntil
    }

    /// Asks macOS for the right to show notifications, if reminders are wanted.
    func prepare() {
        guard remindersOn else { return }
        notifier.requestPermission { [weak self] granted in
            self?.notificationsRefused = !granted
        }
    }

    func setReminders(_ on: Bool) {
        remindersOn = on
        UserDefaults.standard.set(on, forKey: "remindersOn")
        prepare()
    }

    /// No reminder for this long (nil: reminders are back now).
    func snooze(minutes: Int?, now: Date = Date()) {
        let until = minutes.map { now.addingTimeInterval(Double($0) * 60) }
        policy.snooze(until: until)
        snoozedUntil = until
    }

    /// Re-reads the recent rate; when `mayRemind`, shows a reminder if one is due.
    func evaluate(minutes: [MinuteRecord], mayRemind: Bool, now: Date = Date()) {
        if let snoozedUntil, now >= snoozedUntil { self.snoozedUntil = nil }

        let rate = policy.recentRate(records: minutes, now: now)
        let low = rate.flatMap { $0 < Double(threshold) ? $0 : nil }
        if lowRate != low {
            lowRate = low
            onChange?()
        }
        guard mayRemind, remindersOn, let low,
              policy.reminderDue(rate: low, threshold: Double(threshold), now: now) else { return }
        notifier.remind(title: "Time to blink",
                        body: String(format: "About %.0f blinks a minute over the last 3 minutes. "
                                     + "Close your eyes gently a few times.", low))
    }
}

/// Shows the reminder as a macOS notification (the banner at the top right).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    /// macOS only gives notifications to a real app (a bundle with an identifier).
    /// Run as a bare program there is none, and asking would crash.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    private(set) var allowed = false

    /// Asks macOS for the right to show notifications (macOS asks the user once).
    func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else {
            Task { @MainActor in done(false) }
            return
        }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error { Log.app.error("Notifications: \(error.localizedDescription, privacy: .public)") }
            Task { @MainActor in
                self?.allowed = granted
                done(granted)
            }
        }
    }

    func remind(title: String, body: String) {
        guard allowed, let center else {
            // No right to show a banner: a soft sound is better than silence.
            NSSound(named: "Glass")?.play()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // One fixed identifier: a new reminder replaces the previous banner instead of
        // piling up in Notification Centre.
        center.add(UNNotificationRequest(identifier: "low-blink-rate", content: content, trigger: nil))
    }

    // Without this, macOS hides the banner of an app it considers "in front".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Start at login

/// Whether macOS starts the app at login (System Settings > General > Login Items).
@MainActor
final class LoginItem: ObservableObject {

    @Published private(set) var enabled = false
    @Published private(set) var problem: String?

    /// Only a real app (a bundle) can be a login item.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func refresh() {
        guard available else { return }
        enabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ on: Bool) {
        guard available else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch {
            problem = "macOS refused: \(error.localizedDescription)"
            Log.app.error("Login item: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}

// MARK: - Captures

/// Records every frame for a while, for study and for training (diagnostics window).
@MainActor
final class CaptureController: ObservableObject {

    /// Set while a capture is running: what to do, shown in the window.
    @Published private(set) var instruction: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var result: String?

    /// A cued capture: one tick every 1.5 s, 20 times. You blink once at each tick, so
    /// the 30 seconds hold a known number of blinks, at roughly known moments.
    static let cueCount = 20
    static let cueSeconds = 1.5
    static let freeSeconds = 60.0

    var isCapturing: Bool { instruction != nil }

    private let tickSound = NSSound(named: "Tink")
    private var task: Task<Void, Never>?

    /// `cued`: with ticks to blink on; otherwise you carry on and natural blinks are recorded.
    func start(cued: Bool, pipeline: MonitorPipeline, root: URL) {
        guard !isCapturing else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = formatter.string(from: Date()) + (cued ? "-cued" : "-free")

        let writer: CaptureWriter
        do {
            writer = try CaptureWriter(root: root, name: name)
        } catch {
            result = "The capture folder could not be created: \(error.localizedDescription)"
            return
        }

        result = nil
        progress = 0
        instruction = cued
            ? "Blink ONCE at each tick - quick, light blinks, like the ones that get missed."
            : "Carry on normally (read, type). Your natural blinks are being recorded."
        let total = cued ? Double(Self.cueCount) * Self.cueSeconds : Self.freeSeconds

        task = Task {
            pipeline.setCapture(writer)
            withAnimation(.linear(duration: total)) { progress = 1 }
            if cued {
                // Half a second of calm first, then the ticks.
                try? await Task.sleep(nanoseconds: 500_000_000)
                for _ in 0..<Self.cueCount {
                    (tickSound?.copy() as? NSSound)?.play()
                    pipeline.markTick()
                    try? await Task.sleep(nanoseconds: UInt64(Self.cueSeconds * 1_000_000_000))
                }
            } else {
                try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
            }
            pipeline.setCapture(nil)
            instruction = nil
            progress = 0
            result = "Saved \(writer.frames) frames in \(writer.folder.path)"
        }
    }
}

// MARK: - Performance log

/// One line a minute about the pipeline's own cost, in
/// ~/Library/Application Support/BlinkMonitor/performance.csv.
///
/// It answers "what does the app cost on this Mac, hour after hour?" with numbers from
/// real use, not from a benchmark.
struct PerformanceLog {

    let file: URL

    init(file: URL = HistoryStore.applicationFolder.appendingPathComponent("performance.csv")) {
        self.file = file
        // A fresh log when it grows past about a month of minutes.
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 3_000_000 {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func append(_ summary: StageTimings.Summary, at date: Date = Date()) {
        let line = String(format: "%@,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f\n",
                          ISO8601DateFormatter().string(from: date), summary.framesPerSecond, summary.analysedShare,
                          summary.findEyes, summary.crop, summary.model, summary.total, summary.worstTotal)
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "time,frames_per_second,analysed_share,find_eyes_ms,crop_ms,model_ms,frame_ms,worst_frame_ms\n"
                    .write(to: file, atomically: true, encoding: .utf8)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            Log.storage.error("Performance log not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
