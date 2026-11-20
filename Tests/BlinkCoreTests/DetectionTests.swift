import Foundation
import Testing
@testable import BlinkCore

/// The counting rules, on streams of answers written by hand, at 30 frames a second.
@Suite("Counting blinks")
struct DetectionTests {

    private let open = 0.02, closed = 0.98

    @Test("Open, four frames closed, open = one blink of 133 ms")
    func oneBlink() throws {
        let events = Fixture.events(Fixture.frames(open, 15) + Fixture.frames(closed, 4) + Fixture.frames(open, 5))
        #expect(events.count == 1)
        guard case .blink(let blink) = try #require(events.first) else {
            Issue.record("expected a blink, got \(events)")
            return
        }
        #expect(abs(blink.duration - 4.0 / 30) < 0.001)
    }

    @Test("Two blinks in a row are counted twice")
    func twoBlinks() {
        let stream = Fixture.frames(open, 10) + Fixture.frames(closed, 3) + Fixture.frames(open, 10)
            + Fixture.frames(closed, 3) + Fixture.frames(open, 5)
        #expect(Fixture.blinkCount(stream) == 2)
    }

    @Test("One lone, hesitant closed frame is treated as a model mistake")
    func loneUnsureFrame() {
        #expect(Fixture.events(Fixture.frames(open, 10) + [0.7] + Fixture.frames(open, 10)).isEmpty)
    }

    /// A fast blink can be closed on a single frame of a 30-frames-a-second camera.
    @Test("One lone closed frame counts when the model is very sure")
    func loneSureFrame() {
        #expect(Fixture.blinkCount(Fixture.frames(open, 10) + [0.97] + Fixture.frames(open, 10)) == 1)
        #expect(Fixture.blinkCount(Fixture.frames(open, 10) + [0.79] + Fixture.frames(open, 10)) == 0)
    }

    @Test("An answer hovering around 50% is not a blink")
    func hovering() {
        let jitter: [Double?] = (0..<30).map { $0 % 2 == 0 ? 0.45 : 0.55 }
        #expect(Fixture.events(Fixture.frames(open, 5) + jitter + Fixture.frames(open, 5)).isEmpty)
    }

    @Test("A closure that dips to 50% in the middle is still one blink")
    func hysteresis() {
        #expect(Fixture.blinkCount(Fixture.frames(open, 10) + [closed, 0.5, 0.5, closed] + Fixture.frames(open, 5)) == 1)
    }

    @Test("Eyes closed for 1.5 s are a long closure, not a blink")
    func longClosure() throws {
        let events = Fixture.events(Fixture.frames(open, 10) + Fixture.frames(closed, 45) + Fixture.frames(open, 5))
        #expect(events.count == 1)
        guard case .longClosure(let seconds) = try #require(events.first) else {
            Issue.record("expected a long closure, got \(events)")
            return
        }
        #expect(abs(seconds - 1.5) < 0.001)
    }

    @Test("Face lost while the eyes were closed: nothing is counted")
    func gap() {
        let stream = Fixture.frames(open, 10) + Fixture.frames(closed, 2) + Fixture.frames(nil, 30) + Fixture.frames(open, 10)
        #expect(Fixture.events(stream).isEmpty)
    }

    @Test("Eyes already closed when first seen: nothing is counted")
    func startsClosed() {
        #expect(Fixture.events(Fixture.frames(closed, 5) + Fixture.frames(open, 10)).isEmpty)
    }

    // MARK: Combining the two eyes

    @Test("No readable eye gives no answer; one eye gives its own")
    func fusionEdges() {
        #expect(EyeFusion.combine([]) == nil)
        #expect(EyeFusion.combine([0.8]) == 0.8)
    }

    // MARK: Statistics

    @Test("5 blinks in 30 s watched = 10 a minute")
    func rate() throws {
        var stats = BlinkStats()
        for frame in 0...900 { stats.frame(time: Double(frame) / 30, eyesRead: true) }
        for second in [3.0, 9.0, 15.0, 21.0, 27.0] {
            stats.record(.blink(Blink(start: second, end: second + 0.15)))
        }
        stats.record(.longClosure(seconds: 2))

        let rate = try #require(stats.ratePerMinute(inLast: 60, now: 30))
        #expect(abs(rate - 10) < 0.01)
        #expect(stats.totalBlinks == 5 && stats.longClosures == 1)
        #expect(abs(stats.observedSeconds - 30) < 0.001)
    }

    @Test("No rate before 20 s were watched")
    func rateNeedsEvidence() {
        var stats = BlinkStats()
        for frame in 0...300 { stats.frame(time: Double(frame) / 30, eyesRead: true) }
        #expect(stats.ratePerMinute(inLast: 60, now: 10) == nil)
    }

    @Test("Frames without readable eyes are not watched time")
    func awayTime() {
        var stats = BlinkStats()
        for frame in 0...900 { stats.frame(time: Double(frame) / 30, eyesRead: frame < 300) }
        #expect(abs(stats.observedSeconds - 299.0 / 30) < 0.001)
    }

    // MARK: How much work each frame gets

    /// Runs a schedule over `frames` frames; `found` says whether a search finds the eyes.
    private func steps(_ schedule: inout FrameSchedule, frames: Int, found: (Int) -> Bool) -> [FrameSchedule.Step] {
        (0..<frames).map { frame in
            let step = schedule.next()
            if step == .search { schedule.searched(found: found(frame)) }
            return step
        }
    }

    @Test("While the eyes are found, they are searched for on one frame in two")
    func searchEveryOtherFrame() {
        var schedule = FrameSchedule()
        #expect(steps(&schedule, frames: 6) { _ in true }
                == [.search, .reuseSquares, .search, .reuseSquares, .search, .reuseSquares])
    }

    @Test("After a search that finds no face, the very next frame searches again")
    func searchAgainWhenLost() {
        var schedule = FrameSchedule()
        schedule.searchEvery = 3
        // The face is found on the first search, lost on the second, found again after.
        #expect(steps(&schedule, frames: 7) { $0 != 3 }
                == [.search, .reuseSquares, .reuseSquares, .search, .search, .reuseSquares, .reuseSquares])
    }

    @Test("An empty chair: after 3 s without a face, one frame in six is looked at")
    func idle() {
        var schedule = FrameSchedule()
        let first = steps(&schedule, frames: 90) { _ in false }
        #expect(first.allSatisfy { $0 == .search })          // 90 searches, none finds a face

        let idle = steps(&schedule, frames: 60) { _ in false }
        #expect(idle.filter { $0 == .search }.count == 10)   // one in six
        #expect(idle.filter { $0 == .skip }.count == 50)
    }

    @Test("Someone sits down again: full attention from the next search on")
    func backFromIdle() {
        var schedule = FrameSchedule()
        _ = steps(&schedule, frames: 96) { _ in false }
        let back = steps(&schedule, frames: 12) { _ in true }
        // At most five skipped frames (a fifth of a second), then never again.
        let firstSearch = back.firstIndex(of: .search) ?? 99
        #expect(firstSearch <= 5)
        #expect(!back[firstSearch...].contains(.skip))
    }

    @Test("A capture reads every frame in full, whatever the rules say")
    func everyFrame() {
        var schedule = FrameSchedule()
        _ = steps(&schedule, frames: 120) { _ in false }     // idle
        #expect((0..<10).allSatisfy { _ in schedule.next(everyFrame: true) == .search })
    }

    // MARK: Stage timings

    @Test("Measuring adds the time a piece of work took")
    func measure() {
        var seconds = 0.0
        let answer = FrameCost.measure(into: &seconds) { () -> Int in
            Thread.sleep(forTimeInterval: 0.02)
            return 7
        }
        #expect(answer == 7)
        #expect(seconds >= 0.02 && seconds < 0.5)
    }

    @Test("A value behind a lock is changed by one thread at a time")
    func locked() {
        let counter = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in counter.withLock { $0 += 1 } }
        #expect(counter.withLock { $0 } == 2_000)
    }

    @Test("Stage timings average the analysed frames and count the skipped ones")
    func timings() throws {
        var timings = StageTimings()
        for frame in 0..<60 {
            timings.frameDelivered(at: Double(frame) / 30)
            if frame % 2 == 0 {     // every other frame analysed
                var cost = FrameCost()
                cost.findEyes = 0.002
                cost.crop = 0.0005
                cost.model = 0.0002
                cost.total = frame == 10 ? 0.009 : 0.003
                timings.record(cost)
            }
        }
        let taken = timings.takeSummary(at: 2.0)
        let summary = try #require(taken)
        #expect(abs(summary.findEyes - 2.0) < 0.001)
        #expect(abs(summary.total - 3.2) < 0.001)        // (29 x 3 + 9) / 30
        #expect(abs(summary.worstTotal - 9.0) < 0.001)
        #expect(abs(summary.framesPerSecond - 30) < 0.001)
        #expect(abs(summary.analysedShare - 0.5) < 0.001)
        let next = timings.takeSummary(at: 2.5)           // a new stretch, no frame yet
        #expect(next == nil)
    }
}
