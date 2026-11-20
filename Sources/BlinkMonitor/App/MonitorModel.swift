import SwiftUI
import AppKit
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

/// The app's live state - what the camera pipeline says right now - and the place where
/// its parts are connected: camera, pipeline, history, reminders.
///
/// Main thread only; the camera thread hands its results over through `apply`.
@MainActor
final class MonitorModel: ObservableObject {

    enum Stage: Equatable {
        case starting
        case denied
        case failed(String)
        case running
    }

    /// How many seconds of curve the diagnostics window shows.
    static let traceSeconds = 10.0

    // MARK: Live state

    @Published private(set) var stage: Stage = .starting
    /// You chose Pause: the camera is off until you choose Resume.
    @Published private(set) var paused = false
    @Published private(set) var preview: CGImage?
    @Published private(set) var frameSize = CGSize(width: 1920, height: 1080)
    @Published private(set) var eyeRects: [CGRect] = []
    @Published private(set) var faceFound = false
    @Published private(set) var probability: Double?
    @Published private(set) var eyesClosed = false

    @Published private(set) var now = 0.0
    @Published private(set) var trace: [TraceSample] = []
    @Published private(set) var recentBlinks: [Blink] = []

    @Published private(set) var totalBlinks = 0
    @Published private(set) var longClosures = 0
    @Published private(set) var observedSeconds = 0.0
    @Published private(set) var blinksLastMinute = 0
    @Published private(set) var ratePerMinute: Double?
    @Published private(set) var lastBlinkSeconds: Double?
    @Published private(set) var timings: StageTimings.Summary?
    @Published private(set) var problem: String?

    @Published private(set) var statusSummary = StatusSummary(symbol: "eye", text: "", tooltip: "Blink Monitor is starting")

    /// True when the state is made up for screenshots (`loadSample`).
    private(set) var isSample = false

    /// A short sound at every counted blink (while the diagnostics window is open).
    @Published var soundOn = true

    // MARK: Parts

    let history = HistoryController()
    let reminders = ReminderController()
    let loginItem = LoginItem()
    let captures = CaptureController()

    private let camera = CameraCapture()
    private var pipeline: MonitorPipeline?
    private let performanceLog = PerformanceLog()
    private let blinkSound = NSSound(named: "Pop")
    private var asleep = false
    private var diagnosticsOpen = false

    init() {
        reminders.onChange = { [weak self] in self?.refreshStatus() }
    }

    // MARK: - Starting and stopping

    func start() async {
        guard stage == .starting else { return }
        history.load()
        loginItem.refresh()
        reminders.evaluate(minutes: history.minutes, mayRemind: false)

        let classifier: EyeClassifier
        do {
            classifier = try EyeClassifier(compiledModel: Options.modelURL)
        } catch {
            fail("The eye model could not be loaded from \(Options.modelURL.path).\n"
                 + "Make it with: make train\n\(error)")
            return
        }
        let pipeline = MonitorPipeline(classifier: classifier)
        pipeline.setLiveView(diagnosticsOpen)
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

        // Frames come from the camera's thread; the windows belong to the main thread.
        // `DispatchQueue.main.async` hands each result over, in the order it was produced.
        pipeline.onUpdate = { [weak self] update in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(update) }
            }
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
        reminders.prepare()
    }

    private func fail(_ reason: String) {
        Log.app.error("Not started: \(reason, privacy: .private)")   // the reason can hold a path
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
            preview = nil
        }
        refreshStatus()
    }

    /// The diagnostics window shows the camera picture and the curve; only while it is
    /// open does the pipeline prepare the picture and report every frame.
    func setDiagnosticsOpen(_ open: Bool) {
        diagnosticsOpen = open
        pipeline?.setLiveView(open)
        if !open {
            preview = nil
            trace.removeAll()
            recentBlinks.removeAll()
        }
    }

    // MARK: - Frames

    private func apply(_ update: MonitorUpdate) {
        guard !paused, !asleep else { return }   // a last frame can arrive after Pause
        now = update.time
        if let image = update.preview { preview = image }
        if frameSize != update.frameSize { frameSize = update.frameSize }
        if eyeRects != update.eyeRects { eyeRects = update.eyeRects }
        if faceFound != update.faceFound { faceFound = update.faceFound }
        if probability != update.probability { probability = update.probability }
        if eyesClosed != update.eyesClosed { eyesClosed = update.eyesClosed }

        if diagnosticsOpen {
            if let probability = update.probability {
                trace.append(TraceSample(time: update.time, probability: probability))
            }
            let oldest = update.time - Self.traceSeconds - 1
            if let first = trace.first, first.time < oldest {
                trace.removeAll { $0.time < oldest }
                recentBlinks.removeAll { $0.end < oldest }
            }
        }

        if case .blink(let blink) = update.event, diagnosticsOpen {
            recentBlinks.append(blink)
            // Silent during a capture: the ticks are the only sound to follow then.
            if soundOn && !captures.isCapturing {
                // A copy per blink: one NSSound cannot overlap itself.
                (blinkSound?.copy() as? NSSound)?.play()
            }
        }

        if totalBlinks != update.totalBlinks { totalBlinks = update.totalBlinks }
        if longClosures != update.longClosures { longClosures = update.longClosures }
        if abs(observedSeconds - update.observedSeconds) >= 1 || diagnosticsOpen { observedSeconds = update.observedSeconds }
        if blinksLastMinute != update.blinksLastMinute { blinksLastMinute = update.blinksLastMinute }
        if ratePerMinute != update.ratePerMinute { ratePerMinute = update.ratePerMinute }
        if lastBlinkSeconds != update.lastBlinkSeconds { lastBlinkSeconds = update.lastBlinkSeconds }
        if let timings = update.timings { self.timings = timings }
        if let minuteTimings = update.minuteTimings { performanceLog.append(minuteTimings) }
        if let error = update.error { problem = error }

        history.update(current: update.currentMinute)
        if let finished = update.completedMinute {
            history.minuteEnded(finished)
            reminders.evaluate(minutes: history.minutes, mayRemind: true)
        }
        refreshStatus()
    }

    // MARK: - Sample state (screenshots)

    /// A made-up but plausible moment of use, for `--snapshots`: the app after a week,
    /// watching, 13 blinks a minute. The camera is never opened.
    func loadSample(now: Date = Date(), low: Bool = false) {
        isSample = true
        stage = .running
        faceFound = true
        frameSize = CGSize(width: 1920, height: 1080)
        eyeRects = [CGRect(x: 760, y: 430, width: 130, height: 130), CGRect(x: 1030, y: 425, width: 130, height: 130)]
        probability = 0.02
        ratePerMinute = low ? 6 : 13
        blinksLastMinute = low ? 6 : 13
        totalBlinks = 148
        longClosures = 3
        observedSeconds = 11 * 60 + 42
        lastBlinkSeconds = 0.167
        var timings = StageTimings.Summary()
        timings.findEyes = 6.4; timings.crop = 1.3; timings.model = 0.7
        timings.total = 8.6; timings.worstTotal = 21.5; timings.framesPerSecond = 30; timings.analysedShare = 1
        self.timings = timings

        // Ten seconds of curve with three blinks in it.
        self.now = 100
        let blinkStarts = [91.4, 94.9, 98.1]
        trace = (0..<300).map { frame in
            let time = 90 + Double(frame) / 30
            let inBlink = blinkStarts.contains { time >= $0 && time < $0 + 0.13 }
            let edge = blinkStarts.contains { (time >= $0 - 0.034 && time < $0) || (time >= $0 + 0.13 && time < $0 + 0.165) }
            return TraceSample(time: time, probability: inBlink ? 0.98 : (edge ? 0.45 : 0.02))
        }
        recentBlinks = blinkStarts.map { Blink(start: $0, end: $0 + 0.16) }

        history.loadSample(now: now, low: low)
        reminders.loadSample(lowRate: low ? 6.2 : nil)
        refreshStatus()
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
                if let lowRate = reminders.lowRate {
                    summary = StatusSummary(symbol: "eye.trianglebadge.exclamationmark", text: text,
                                            tooltip: String(format: "You blink too little: %.0f a minute over the last 3 minutes", lowRate))
                } else {
                    summary = StatusSummary(symbol: "eye", text: text, tooltip: "Blinks per minute, over the last minute")
                }
            }
        }
        if statusSummary != summary { statusSummary = summary }
    }

    // MARK: - Diagnostics window

    func resetCounters() {
        pipeline?.requestReset()
        trace.removeAll()
        recentBlinks.removeAll()
    }

    func startCapture(cued: Bool) {
        guard stage == .running, !paused, let pipeline else { return }
        captures.start(cued: cued, pipeline: pipeline, root: Options.captureRoot)
    }
}
