import Foundation
import Testing
@testable import BlinkCore

@Suite("Pauses, screen time and the blink break")
struct PauseAndBreakTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 16:30 UTC.
    private let afternoon = Date(timeIntervalSince1970: 1_800_289_800)

    // MARK: Pause

    @Test("A timed pause ends by itself; an open one waits for you")
    func pauseEnds() {
        let quarter = PauseState(.fifteenMinutes, from: afternoon, calendar: calendar)
        #expect(quarter == .paused(until: afternoon.addingTimeInterval(900)))
        #expect(quarter.isPaused(at: afternoon.addingTimeInterval(899)))
        #expect(quarter.resolved(at: afternoon.addingTimeInterval(900)) == .running)

        let open = PauseState(.untilResumed, from: afternoon, calendar: calendar)
        #expect(open == .paused(until: nil) && open.end == nil)
        #expect(open.isPaused(at: afternoon.addingTimeInterval(30 * 86_400)))
        #expect(!PauseState.running.isPaused(at: afternoon))
    }

    @Test("Until tomorrow means the next midnight, not 24 hours")
    func untilTomorrow() throws {
        let end = try #require(PauseState(.untilTomorrow, from: afternoon, calendar: calendar).end)
        #expect(end == calendar.startOfDay(for: afternoon).addingTimeInterval(86_400))
        #expect(end.timeIntervalSince(afternoon) == 7.5 * 3600)
    }

    @Test("The status carries the pause's end; a sleeping screen is a pause with none")
    func pausedStatus() {
        let until = afternoon.addingTimeInterval(3600)
        #expect(MonitorStatus(lifecycle: .running, pause: .paused(until: until), faceFound: true, rate: 13, recentLowRate: 4)
                == .paused(until: until))
        #expect(MonitorStatus(lifecycle: .running, asleep: true, faceFound: true, rate: 13, recentLowRate: nil)
                == .paused(until: nil))
        #expect(MonitorStatus(lifecycle: .cameraRefused, pause: .paused(until: until), faceFound: false, rate: nil, recentLowRate: nil)
                == .cameraRefused)
    }

    // MARK: Time at the screen

    /// Feeds one frame a second from `from` to `to`.
    private func watch(_ tracker: inout PresenceTracker, from: Int, to: Int, face: Bool) {
        for second in from...to { tracker.frame(time: Double(second), faceFound: face) }
    }

    @Test("Time at the screen runs while a face is in view")
    func presenceCounts() {
        var tracker = PresenceTracker()
        #expect(tracker.continuousSeconds(at: 0) == 0)
        watch(&tracker, from: 100, to: 700, face: true)
        #expect(tracker.continuousSeconds(at: 700) == 600)
    }

    @Test("Looking away for a few seconds is not a break; twenty seconds is")
    func presenceBreaks() {
        var tracker = PresenceTracker()
        watch(&tracker, from: 0, to: 600, face: true)
        watch(&tracker, from: 601, to: 610, face: false)          // ten seconds away
        watch(&tracker, from: 611, to: 700, face: true)
        #expect(tracker.continuousSeconds(at: 700) == 700)

        watch(&tracker, from: 701, to: 730, face: false)          // thirty seconds away
        #expect(tracker.continuousSeconds(at: 730) == 0)          // on a break right now
        watch(&tracker, from: 731, to: 791, face: true)
        #expect(tracker.continuousSeconds(at: 791) == 60)         // counted from the return
    }

    @Test("A nudge restarts the count, and so does a camera that was off")
    func presenceRestarts() {
        var tracker = PresenceTracker()
        watch(&tracker, from: 0, to: 1200, face: true)
        tracker.restart(at: 1200)
        #expect(tracker.continuousSeconds(at: 1200) == 0)
        watch(&tracker, from: 1201, to: 1260, face: true)
        #expect(tracker.continuousSeconds(at: 1260) == 60)

        // The camera was paused for an hour: no frame at all in between.
        watch(&tracker, from: 4860, to: 4900, face: true)
        #expect(tracker.continuousSeconds(at: 4900) == 40)

        // A clock that starts again from zero starts a new stretch, never a negative one.
        watch(&tracker, from: 5, to: 15, face: true)
        #expect(tracker.continuousSeconds(at: 15) == 10)
    }

    // MARK: Blink break

    @Test("Every completed closure up to 3 s counts: the exercise's blinks are slow on purpose")
    func blinkBreakCounts() {
        var exercise = BlinkBreak(target: 3)
        exercise.record(.blink(Blink(start: 1, end: 1.2)))
        #expect(exercise.count == 1 && !exercise.isDone)
        exercise.record(.longClosure(seconds: 1.4))               // a slow, full blink
        #expect(exercise.count == 2)
        exercise.record(.longClosure(seconds: 8))                 // resting: not a blink
        #expect(exercise.count == 2)
        exercise.record(.longClosure(seconds: 3))
        #expect(exercise.count == 3 && exercise.isDone && exercise.progress == 1)
    }

    @Test("A finished break stops counting, and its progress fills evenly")
    func blinkBreakStops() {
        var exercise = BlinkBreak(target: 10)
        #expect(exercise.progress == 0)
        for _ in 0..<4 { exercise.record(.blink(Blink(start: 0, end: 0.2))) }
        #expect(exercise.progress == 0.4)
        for _ in 0..<20 { exercise.record(.blink(Blink(start: 0, end: 0.2))) }
        #expect(exercise.count == 10 && exercise.progress == 1)
        #expect(BlinkBreak(target: 0).target == 1)
    }

    @Test("The monitor's own counting is untouched: a slow blink is still a long closure there")
    func normalCountingUnchanged() {
        var stats = BlinkStats()
        stats.record(.longClosure(seconds: 1.4))
        #expect(stats.totalBlinks == 0 && stats.longClosures == 1)
    }
}
