import CoreGraphics
import CoreVideo
import Testing
@testable import BlinkCore

@Suite("The effort: how often the eyes are looked for")
struct EffortTests {

    @Test("Standard is the schedule of before the choice existed; light searches one frame in 3, thorough every frame")
    func rhythms() {
        let usual = FrameSchedule()
        #expect(Effort.standard.schedule.searchEvery == usual.searchEvery && usual.searchEvery == 2)
        #expect(Effort.standard.schedule.strayBeyond == nil && usual.strayBeyond == nil)
        #expect(Effort.light.schedule.searchEvery == 3 && Effort.light.schedule.strayBeyond == 0.35)
        #expect(Effort.thorough.schedule.searchEvery == 1 && Effort.thorough.schedule.strayBeyond == nil)
        #expect(Effort.allCases.map(\.searchesASecond) == [10, 15, 30])
    }

    @Test("No level changes what happens at an empty chair: none is slower to notice a face coming back")
    func emptyChair() {
        let usual = FrameSchedule()
        for effort in Effort.allCases {
            #expect(effort.schedule.idleAfterSearches == usual.idleAfterSearches, "\(effort)")
            #expect(effort.schedule.idleStride == usual.idleStride, "\(effort)")
        }
    }

    @Test("The words kept on disk are light, standard, thorough")
    func storedWords() {
        #expect(Effort.allCases.map(\.rawValue) == ["light", "standard", "thorough"])
    }

    @Test("Each level carries what it was measured to cost and to count; more searches are more work")
    func measured() {
        for effort in Effort.allCases {
            let measured = effort.measured
            #expect(measured.marked == 80 && measured.found > 0 && measured.found <= measured.marked, "\(effort)")
            #expect(measured.instructions > 0 && measured.processor > 0 && measured.milliwatts > 0, "\(effort)")
        }
        #expect(Effort.light.measured.instructions < Effort.standard.measured.instructions)
        #expect(Effort.standard.measured.instructions < Effort.thorough.measured.instructions)
        #expect(Effort.standard.workAgainstStandard == 0)
        #expect(Effort.light.workAgainstStandard < 0 && Effort.thorough.workAgainstStandard > 0)
        // What the lower level gives up is said in blinks: it must not have found more.
        #expect(Effort.light.measured.found <= Effort.standard.measured.found)
    }

    // MARK: Squares the eyes have left

    /// Eyes 200 pixels apart, `dx` further to the right.
    private func eyes(dx: CGFloat = 0) -> LocatedEyes {
        let left = CGPoint(x: 400 + dx, y: 300), right = CGPoint(x: 600 + dx, y: 300)
        let rects = EyeLocator.cropRects(leftCenter: left, rightCenter: right)
        return LocatedEyes(faceRect: .zero,
                           left: EyeRegion(side: .imageLeft, cropRect: rects.left, center: left),
                           right: EyeRegion(side: .imageRight, cropRect: rects.right, center: right),
                           interocularDistance: rects.distance, roll: nil, yaw: nil)
    }

    @Test("How far the eyes moved is the move of the eye that moved most, in eye distances")
    func moved() {
        #expect(eyes().moved(since: eyes()) == 0)
        #expect(abs(eyes(dx: 50).moved(since: eyes()) - 0.25) < 1e-9)
        #expect(abs(eyes(dx: -80).moved(since: eyes()) - 0.4) < 1e-9)
    }

    @Test("Past the limit the eyes have left their squares; with no limit they never have")
    func strayed() {
        #expect(!Effort.light.schedule.strayed(moved: 0.34))
        #expect(Effort.light.schedule.strayed(moved: 0.36))
        #expect(!Effort.standard.schedule.strayed(moved: 5))
        #expect(!Effort.thorough.schedule.strayed(moved: 5))
    }

    /// Finds the eyes where it is told, one place for each search.
    private final class MovingEyes: EyeLocating {
        var places: [LocatedEyes]
        private(set) var searches = 0
        init(_ places: [LocatedEyes]) { self.places = places }

        func locate(in pixelBuffer: CVPixelBuffer) throws -> LocatedEyes? {
            defer { searches += 1 }
            return places[min(searches, places.count - 1)]
        }
    }

    /// What six frames say about straying, for a head that jumps 80 pixels (0.4 of the
    /// eye distance) between the first search and the second.
    private func strays(_ effort: Effort) throws -> [Bool] {
        let finder = EyeFinder(locator: MovingEyes([eyes(), eyes(dx: 80)]), schedule: effort.schedule)
        let frame = Fixture.frame()
        var cost = FrameCost()
        return try (0..<6).map { _ in
            guard case .found(let found) = try finder.find(in: frame, cost: &cost) else { return false }
            return found.strayed
        }
    }

    @Test("Light: the search that finds the eyes out of the squares two frames read says so, once")
    func finderSaysStrayed() throws {
        // search, old squares, old squares, search (the eyes are elsewhere), old, old.
        #expect(try strays(.light) == [false, false, false, true, false, false])
        // Standard keeps trusting squares one frame old, as it always did.
        #expect(try strays(.standard) == [false, false, false, false, false, false])
        // Thorough has no old squares: every frame is searched.
        #expect(try strays(.thorough) == [false, false, false, false, false, false])
    }

    @Test("A closure read in squares the eyes had left is forgotten, not counted")
    func strayedClosureIsDropped() {
        func reading(_ closed: Double, strayed: Bool = false) -> FrameReading {
            var reading = FrameReading()
            reading.faceFound = true
            reading.closed = closed
            reading.strayed = strayed
            return reading
        }
        func blinks(_ stream: [FrameReading]) -> Int {
            var detector = BlinkDetector(), count = 0
            for (frame, reading) in stream.enumerated() {
                if case .blink = detector.update(time: Double(frame) / 30, reading: reading) { count += 1 }
            }
            return count
        }
        let open = reading(0.02), closed = reading(0.97)
        // Open, closed on two frames, open again: a blink.
        #expect(blinks([open, open, closed, closed, open, open]) == 1)
        // The same answers, but the frame that reads "open" again found the eyes out of
        // the squares the two "closed" frames had read: nothing is counted.
        #expect(blinks([open, open, closed, closed, reading(0.02, strayed: true), open]) == 0)
        // Counting goes on afterwards.
        #expect(blinks([open, closed, closed, reading(0.02, strayed: true), open, closed, closed, open]) == 1)
    }
}
