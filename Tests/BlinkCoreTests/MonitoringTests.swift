import Foundation
import Testing
@testable import BlinkCore

/// The situation the windows describe is decided in one place, from the facts.
@Suite("What the monitor is doing")
struct MonitoringTests {

    private func status(_ lifecycle: Lifecycle = .running, paused: Bool = false, face: Bool = true,
                        rate: Double? = 13, low: Double? = nil) -> MonitorStatus {
        MonitorStatus(lifecycle: lifecycle, pause: paused ? .paused(until: nil) : .running, faceFound: face,
                      rate: rate, recentLowRate: low)
    }

    @Test("Before the camera runs, the lifecycle decides - whatever else is known")
    func lifecycleFirst() {
        #expect(status(.starting, low: 4) == .starting)
        #expect(status(.cameraRefused, paused: true) == .cameraRefused)
        #expect(status(.failed("no model"), face: false) == .failed("no model"))
    }

    @Test("Paused wins over everything the camera said last")
    func paused() {
        #expect(status(paused: true, face: true, low: 4) == .paused(until: nil))
    }

    @Test("Nobody in view is not 'low': time away is not blinking too little")
    func noFace() {
        #expect(status(face: false, low: 4) == .noFace)
    }

    @Test("A camera that sends nothing is said - but a pause still wins, and it is not 'on'")
    func cameraSilent() {
        let silent = MonitorStatus(lifecycle: .running, cameraSilent: true, faceFound: true, rate: 13, recentLowRate: 4)
        #expect(silent == .cameraSilent && !silent.isCameraOn && silent.rate == nil)
        #expect(MonitorStatus(lifecycle: .running, pause: .paused(until: nil), cameraSilent: true, faceFound: true,
                              rate: 13, recentLowRate: nil) == .paused(until: nil))
        #expect(MonitorStatus(lifecycle: .starting, cameraSilent: true, faceFound: false, rate: nil, recentLowRate: nil) == .starting)
    }

    @Test("Watching, with the rate once there is one")
    func watching() {
        #expect(status(rate: nil) == .watching(rate: nil))
        #expect(status(rate: 13) == .watching(rate: 13))
        #expect(status(rate: 13).rate == 13)
    }

    @Test("Low carries both the rate shown and the three-minute rate that made it low")
    func low() {
        #expect(status(rate: 9, low: 6.2) == .low(rate: 9, recent: 6.2))
    }

    @Test("The camera counts as on only while the pipeline runs")
    func cameraOn() {
        #expect(status().isCameraOn && status(face: false).isCameraOn && status(low: 5).isCameraOn)
        #expect(!status(paused: true).isCameraOn && !status(.starting).isCameraOn && !status(.cameraRefused).isCameraOn)
    }

    // MARK: Low rate, computed

    private let ten = Date(timeIntervalSince1970: 1_800_000_000)

    private var quietMinutes: [MinuteRecord] {
        (0..<3).map { MinuteRecord(start: ten.addingTimeInterval(Double($0) * 60), observedSeconds: 60, blinks: 6) }
    }

    @Test("The low rate follows the threshold at once: nothing is stored to go stale")
    func lowRateFollowsThreshold() throws {
        let policy = ReminderPolicy()
        let now = ten.addingTimeInterval(180)
        #expect(try #require(policy.lowRate(records: quietMinutes, threshold: 10, now: now)) == 6)
        #expect(policy.lowRate(records: quietMinutes, threshold: 5, now: now) == nil)
        #expect(policy.lowRate(records: [], threshold: 10, now: now) == nil)
    }

    // MARK: The counters as one value

    @Test("A snapshot holds every counter a window shows")
    func snapshot() {
        var stats = BlinkStats()
        for frame in 0...900 { stats.frame(time: Double(frame) / 30, eyesRead: true) }
        stats.record(.blink(Blink(start: 5, end: 5.15)))
        stats.record(.blink(Blink(start: 20, end: 20.2)))
        stats.record(.longClosure(seconds: 1.2))

        let snapshot = stats.snapshot(now: 30)
        #expect(snapshot.totalBlinks == 2 && snapshot.longClosures == 1 && snapshot.blinksLastMinute == 2)
        #expect(abs(snapshot.observedSeconds - 30) < 0.001)
        #expect(snapshot.ratePerMinute.map { abs($0 - 4) < 0.01 } == true)
        #expect(snapshot.lastBlinkSeconds.map { abs($0 - 0.2) < 0.001 } == true)
        #expect(BlinkStats().snapshot(now: 0) == BlinkStats.Snapshot())
    }

    @Test("Automatic takes the Mac's own camera and moves on after ten silent seconds; a chosen camera is never left")
    func cameraChoice() {
        let own = CameraOption(id: "own", name: "FaceTime HD Camera", builtIn: true)
        let desk = CameraOption(id: "desk", name: "Studio Display Camera", builtIn: false)
        let third = CameraOption(id: "third", name: "Webcam", builtIn: false)
        #expect(CameraChoice.pick(from: [desk, own], wanted: nil) == own)
        #expect(CameraChoice.pick(from: [desk, third], wanted: nil) == desk, "a Mac with no camera of its own takes the first")
        #expect(CameraChoice.pick(from: [own, desk], wanted: "desk") == desk)
        #expect(CameraChoice.pick(from: [own], wanted: "desk") == own, "a chosen camera that was unplugged")
        #expect(CameraChoice.pick(from: [], wanted: nil) == nil)

        // Lid closed, docked: the Mac's own camera says nothing.
        #expect(CameraChoice.fallback(from: [own, desk], current: "own", wanted: nil, silentSeconds: 9) == nil)
        #expect(CameraChoice.fallback(from: [own, desk], current: "own", wanted: nil, silentSeconds: 10) == desk)
        #expect(CameraChoice.fallback(from: [own, desk], current: "own", wanted: "own", silentSeconds: 60) == nil)
        #expect(CameraChoice.fallback(from: [own], current: "own", wanted: nil, silentSeconds: 60) == nil)
        // Once round, then it stays: no swapping for ever in the dark.
        #expect(CameraChoice.fallback(from: [own, desk, third], current: "desk", wanted: nil, silentSeconds: 10, tried: ["own", "desk"]) == third)
        #expect(CameraChoice.fallback(from: [own, desk, third], current: "third", wanted: nil, silentSeconds: 10,
                                      tried: ["own", "desk", "third"]) == nil)
    }

    @Test("Quit asks only when something would be lost: a timer, a recording, a training")
    func quitQuestion() {
        #expect(QuitQuestion.question(.init()) == nil, "an ordinary quit is immediate")
        #expect(QuitQuestion.question(.init(timer: "Heated eye mask"))?.text.contains("Heated eye mask") == true)
        #expect(QuitQuestion.question(.init(recording: true))?.title == "A recording is in progress")
        #expect(QuitQuestion.question(.init(training: true))?.title == "Your model is being trained")
        // The timer goes first: covered eyes are waiting for its sound.
        #expect(QuitQuestion.question(.init(timer: "Mask", recording: true, training: true))?.title == "A timer is running")
    }

    @Test("Delete everything removes the folder it is given and the settings under the name it is given, and nothing else")
    func uninstall() throws {
        // A folder and a settings store of this test's own: never the app's real ones.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("blink-uninstall-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("BlinkMonitor", isDirectory: true)
        let beside = base.appendingPathComponent("beside.txt")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sessions/one"), withIntermediateDirectories: true)
        try Data("minute".utf8).write(to: folder.appendingPathComponent("history.csv"))
        try Data("kept".utf8).write(to: beside)
        let domain = "blink-uninstall-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(7, forKey: "floor")
        defer {
            try? FileManager.default.removeItem(at: base)
            defaults.removePersistentDomain(forName: domain)
        }

        try Uninstall.deleteEverything(folder: folder, defaults: defaults, domain: domain)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: beside.path), "what is beside the folder is not the app's")
        #expect(defaults.object(forKey: "floor") == nil)
        // A second time, with nothing left: not an error.
        try Uninstall.deleteEverything(folder: folder, defaults: defaults, domain: domain)
    }
}
