import SwiftUI
import AppKit
import ServiceManagement
import BlinkCore

/// One point of the live curve: the model's answer at one moment.
struct TraceSample {
    let time: Double
    let probability: Double
}

/// What the menu bar shows: a symbol and a short text.
struct StatusSummary: Equatable {
    var symbol: String
    var text: String
    var tooltip: String
}

/// The app's state: everything the menu bar, its panel and the live window show.
/// Main thread only; the camera thread hands frames over through `apply`.
@MainActor
final class MonitorModel: ObservableObject {

    enum Stage: Equatable {
        case starting
        case denied
        case failed(String)
        case running
    }

    /// How many seconds of curve the live window shows.
    static let traceSeconds = 10.0

    // MARK: Live state

    @Published var stage: Stage = .starting
    /// You chose Pause: the camera is off until you choose Resume.
    @Published var paused = false
    @Published var preview: CGImage?
    @Published var frameSize = CGSize(width: 1920, height: 1080)
    @Published var eyeRects: [CGRect] = []
    @Published var faceFound = false
    @Published var probability: Double?
    @Published var eyesClosed = false

    @Published var now = 0.0
    @Published var trace: [TraceSample] = []
    @Published var recentBlinks: [Blink] = []

    @Published var totalBlinks = 0
    @Published var longClosures = 0
    @Published var observedSeconds = 0.0
    @Published var blinksLastMinute = 0
    @Published var ratePerMinute: Double?
    @Published var lastBlinkSeconds: Double?
    @Published var problem: String?

    @Published var statusSummary = StatusSummary(symbol: "eye", text: "", tooltip: "Blink Monitor is starting")

    // MARK: History and reminders

    /// The last 24 hours, minute by minute (finished minutes only).
    @Published var minutes: [MinuteRecord] = []
    @Published var currentMinute: MinuteRecord?
    /// Your rate over the last 3 minutes while it is under the threshold, else nil.
    @Published var lowRate: Double?

    /// "Blinking too little" starts under this many blinks a minute. People at rest blink
    /// roughly 15 to 20 times a minute, and far less when staring at a screen; 10 is a
    /// starting point for you to adjust, not a medical limit.
    @Published var threshold: Int {
        didSet {
            UserDefaults.standard.set(threshold, forKey: "threshold")
            refreshLowRate()
        }
    }
    @Published var remindersOn: Bool {
        didSet { UserDefaults.standard.set(remindersOn, forKey: "remindersOn") }
    }
    @Published var notificationsRefused = false
    @Published var startsAtLogin = false
    @Published var loginProblem: String?

    /// A short sound at every detected blink (while the live window is open).
    @Published var soundOn = true

    // MARK: Capture (live window)

    @Published var captureInstruction: String?
    @Published var captureProgress = 0.0
    @Published var captureResult: String?

    static let cueCount = 20
    static let cueSeconds = 1.5
    static let freeSeconds = 60.0

    // MARK: Private

    private let camera = CameraCapture()
    private var pipeline: MonitorPipeline?
    private let history = HistoryStore(file: HistoryStore.defaultFile)
    private var policy = ReminderPolicy()
    private let notifier = Notifier()
    private let blinkSound = NSSound(named: "Pop")
    private let tickSound = NSSound(named: "Tink")
    private var captureTask: Task<Void, Never>?
    private var asleep = false
    private var liveWindowOpen = false

    init() {
        let defaults = UserDefaults.standard
        threshold = defaults.object(forKey: "threshold") as? Int ?? 10
        remindersOn = defaults.object(forKey: "remindersOn") as? Bool ?? true
    }

    // MARK: - Starting and stopping

    func start() async {
        guard stage == .starting else { return }
        minutes = history.load(since: Date().addingTimeInterval(-24 * 3600))
        refreshLoginState()

        let classifier: EyeClassifier
        do {
            classifier = try EyeClassifier(compiledModel: Options.modelURL)
        } catch {
            fail("The eye model could not be loaded from \(Options.modelURL.path).\n"
                 + "Make it with: cd training && uv run python convert.py\n\(error)")
            return
        }
        let pipeline = MonitorPipeline(classifier: classifier)
        pipeline.setPreview(liveWindowOpen)
        self.pipeline = pipeline

        if Options.noCamera {
            fail("The camera is off (--no-camera). The model loaded correctly.")
            return
        }
        guard await CameraCapture.requestPermission() else {
            stage = .denied
            refreshStatus()
            return
        }

        pipeline.onUpdate = { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        let camera = self.camera
        let failure: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try camera.start { pixelBuffer, time in pipeline.process(pixelBuffer, time: time) }
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: "\(error)")
                }
            }
        }
        if let failure {
            fail(failure)
            return
        }
        stage = .running
        refreshStatus()
        if remindersOn { askForNotifications() }
    }

    private func fail(_ reason: String) {
        stage = .failed(reason)
        refreshStatus()
    }

    /// Pause turns the camera off for real: its green light goes out.
    func setPaused(_ value: Bool) {
        paused = value
        applyCameraState()
    }

    /// The Mac's screen went to sleep, or woke up. Nobody is in front of a sleeping
    /// screen: the camera is switched off until it wakes.
    func setAsleep(_ value: Bool) {
        asleep = value
        applyCameraState()
    }

    private func applyCameraState() {
        guard stage == .running else { return }
        let run = !paused && !asleep
        let camera = self.camera
        DispatchQueue.global(qos: .userInitiated).async {
            if run { camera.resume() } else { camera.stop() }
        }
        if !run {
            faceFound = false
            probability = nil
            eyesClosed = false
            ratePerMinute = nil
            eyeRects = []
        }
        refreshStatus()
    }

    /// The live window shows the camera picture; the pipeline only prepares it meanwhile.
    func setLiveWindowOpen(_ open: Bool) {
        liveWindowOpen = open
        pipeline?.setPreview(open)
        if !open { preview = nil }
    }

    // MARK: - Frames

    private func apply(_ update: MonitorUpdate) {
        guard !paused, !asleep else { return }   // a last frame can arrive after Pause
        now = update.time
        if let image = update.preview { preview = image }
        frameSize = update.frameSize
        if eyeRects != update.eyeRects { eyeRects = update.eyeRects }
        if faceFound != update.faceFound { faceFound = update.faceFound }
        probability = update.probability
        if eyesClosed != update.eyesClosed { eyesClosed = update.eyesClosed }

        // The curve is only kept while the live window can show it.
        if liveWindowOpen {
            if let probability = update.probability {
                trace.append(TraceSample(time: update.time, probability: probability))
            }
            let oldest = update.time - Self.traceSeconds - 1
            if let first = trace.first, first.time < oldest {
                trace.removeAll { $0.time < oldest }
                recentBlinks.removeAll { $0.end < oldest }
            }
        }

        if case .blink(let blink) = update.event {
            if liveWindowOpen { recentBlinks.append(blink) }
            // Silent during a capture: the ticks are the only sound to follow then.
            if soundOn && liveWindowOpen && captureInstruction == nil {
                // A copy per blink: one NSSound cannot overlap itself.
                (blinkSound?.copy() as? NSSound)?.play()
            }
        }

        if totalBlinks != update.totalBlinks { totalBlinks = update.totalBlinks }
        if longClosures != update.longClosures { longClosures = update.longClosures }
        observedSeconds = update.observedSeconds
        if blinksLastMinute != update.blinksLastMinute { blinksLastMinute = update.blinksLastMinute }
        if ratePerMinute != update.ratePerMinute { ratePerMinute = update.ratePerMinute }
        if lastBlinkSeconds != update.lastBlinkSeconds { lastBlinkSeconds = update.lastBlinkSeconds }
        if let error = update.error { problem = error }

        if let minute = update.currentMinute { currentMinute = minute }
        if let finished = update.completedMinute { minuteEnded(finished) }
        refreshStatus()
    }

    // MARK: - History and reminders

    private func minuteEnded(_ minute: MinuteRecord) {
        // A minute in which the eyes were never read (you were away) is not a record.
        if minute.observedSeconds >= 1 {
            minutes.append(minute)
            history.append(minute)
        }
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        if let first = minutes.first, first.start < dayAgo {
            minutes.removeAll { $0.start < dayAgo }
        }

        refreshLowRate()
        let date = Date()
        if remindersOn, policy.reminderDue(rate: lowRate, threshold: Double(threshold), now: date), let lowRate {
            notifier.remind(title: "Time to blink",
                            body: String(format: "About %.0f blinks a minute over the last 3 minutes. "
                                         + "Close your eyes gently a few times.", lowRate))
        }
    }

    private func refreshLowRate() {
        let rate = policy.recentRate(records: minutes, now: Date())
        let low = rate.flatMap { $0 < Double(threshold) ? $0 : nil }
        if lowRate != low { lowRate = low }
        refreshStatus()
    }

    /// Today's minutes, including the one being filled.
    var today: DaySummary {
        let calendar = Calendar.current
        var records = minutes.filter { calendar.isDateInToday($0.start) }
        if let currentMinute, calendar.isDateInToday(currentMinute.start) { records.append(currentMinute) }
        return DaySummary(records: records, threshold: Double(threshold))
    }

    func setReminders(_ on: Bool) {
        remindersOn = on
        if on { askForNotifications() }
    }

    private func askForNotifications() {
        notifier.requestPermission { [weak self] granted in
            self?.notificationsRefused = !granted
        }
    }

    // MARK: - Menu bar

    private func refreshStatus() {
        let summary: StatusSummary
        switch stage {
        case .starting:
            summary = StatusSummary(symbol: "eye", text: "", tooltip: "Blink Monitor is starting")
        case .denied:
            summary = StatusSummary(symbol: "eye.slash", text: "!", tooltip: "Blink Monitor: camera access refused")
        case .failed(let reason):
            summary = StatusSummary(symbol: "exclamationmark.triangle", text: "", tooltip: "Blink Monitor: \(reason)")
        case .running:
            if paused || asleep {
                summary = StatusSummary(symbol: "eye.slash", text: "", tooltip: "Blink Monitor is paused")
            } else if !faceFound {
                summary = StatusSummary(symbol: "eye", text: "--", tooltip: "Blink Monitor: no face in view")
            } else {
                let text = ratePerMinute.map { String(format: "%.0f", $0) } ?? "--"
                if let lowRate {
                    summary = StatusSummary(symbol: "eye.trianglebadge.exclamationmark", text: text,
                                            tooltip: String(format: "You blink too little: %.0f a minute over the last 3 minutes", lowRate))
                } else {
                    summary = StatusSummary(symbol: "eye", text: text, tooltip: "Blinks per minute, over the last minute")
                }
            }
        }
        if statusSummary != summary { statusSummary = summary }
    }

    // MARK: - Start at login

    private func refreshLoginState() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Registers the app with macOS as a login item (System Settings > General > Login Items).
    func setStartsAtLogin(_ on: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = nil
        } catch {
            loginProblem = "macOS refused: \(error.localizedDescription)"
        }
        refreshLoginState()
    }

    // MARK: - Live window: counters and captures

    func reset() {
        pipeline?.requestReset()
        trace.removeAll()
        recentBlinks.removeAll()
    }

    /// Records every frame for a while. `cued`: with ticks to blink on; otherwise you
    /// simply carry on (read, type) and your natural blinks are recorded.
    func startCapture(cued: Bool) {
        guard stage == .running, !paused, captureInstruction == nil, let pipeline else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = formatter.string(from: Date()) + (cued ? "-cued" : "-free")

        let writer: CaptureWriter
        do {
            writer = try CaptureWriter(root: Options.captureRoot, name: name)
        } catch {
            captureResult = "The capture folder could not be created: \(error.localizedDescription)"
            return
        }

        captureResult = nil
        captureProgress = 0
        captureInstruction = cued
            ? "Blink ONCE at each tick - quick, light blinks, like the ones that get missed."
            : "Carry on normally (read, type). Your natural blinks are being recorded."
        let total = cued ? Double(Self.cueCount) * Self.cueSeconds : Self.freeSeconds

        captureTask = Task {
            pipeline.setCapture(writer)
            withAnimation(.linear(duration: total)) { captureProgress = 1 }
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
            captureInstruction = nil
            captureProgress = 0
            captureResult = "Saved \(writer.frames) frames in data/live/\(name)"
        }
    }
}
