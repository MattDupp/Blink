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
}
