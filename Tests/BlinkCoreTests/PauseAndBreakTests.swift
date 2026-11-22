import Foundation
import Testing
@testable import BlinkCore

@Suite("Pauses and the blink break")
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
