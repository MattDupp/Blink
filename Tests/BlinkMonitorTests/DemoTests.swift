import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

/// The demo: made-up eyes, counted by the real code.
@MainActor
@Suite("The demo", .serialized)
struct DemoTests {

    /// Runs `seconds` of made-up frames through a real pipeline; returns what it reported.
    private func run(seconds: Double, pace: DemoEyes.Pace) -> [MonitorUpdate] {
        var eyes = DemoEyes()
        eyes.pace = pace
        let pipeline = MonitorPipeline()
        pipeline.setLiveView(true)                 // report every frame
        var updates: [MonitorUpdate] = []
        pipeline.onUpdate = { updates.append($0) }
        for frame in 0..<Int(seconds * 30) {
            let time = 1000 + Double(frame) / 30
            pipeline.process(eyes.reading(at: time), time: time)
        }
        return updates
    }

    @Test("Made-up eyes blink like a person at a screen: about 13 times a minute")
    func usualPace() throws {
        let updates = run(seconds: 600, pace: .usual)
        let blinks = updates.filter { if case .blink = $0.event { return true } else { return false } }.count
        #expect((100...160).contains(blinks), "\(blinks) blinks in ten minutes")
        let rate = try #require(updates.last?.live.counters.ratePerMinute)
        #expect((8...18).contains(rate))
        #expect(updates.allSatisfy { $0.live.faceFound && $0.live.eyeAnswers.count == 2 })
    }

    @Test("During a blink break they do the exercise: slow blinks, which only the break counts")
    func exercisePace() {
        let updates = run(seconds: 30, pace: .exercise)
        var exercise = BlinkBreak()
        var counted = 0
        for update in updates {
            guard let event = update.event else { continue }
            exercise.record(event)
            if case .blink = event { counted += 1 }
        }
        #expect(exercise.isDone, "\(exercise.count) of \(exercise.target) in 30 s")
        #expect(counted == 0)
    }

    @Test("The pipeline reports exactly the events the blink detector finds, in the same order")
    func pipelineCountsWhatTheDetectorCounts() {
        // The same stream twice: once through the pipeline the app uses, once through the
        // detector alone. Splitting the pipeline to make room for the demo must not have
        // changed what is counted.
        var eyes = DemoEyes(seed: 7)
        var readings: [(reading: FrameReading, time: Double)] = []
        for frame in 0..<(300 * 30) {
            let time = 500 + Double(frame) / 30
            if frame == 4000 { eyes.pace = .exercise }
            if frame == 5500 { eyes.pace = .usual }
            var reading = eyes.reading(at: time)
            if (6000..<6040).contains(frame) { reading = FrameReading() }      // the face is lost for a moment
            readings.append((reading, time))
        }

        let pipeline = MonitorPipeline()
        var reported: [BlinkDetector.Event] = []
        pipeline.onUpdate = { if let event = $0.event { reported.append(event) } }
        var detector = BlinkDetector()
        var expected: [BlinkDetector.Event] = []
        for (reading, time) in readings {
            pipeline.process(reading, time: time)
            if let event = detector.update(time: time, closed: reading.closed) { expected.append(event) }
        }
        #expect(reported == expected)
        #expect(expected.count > 60, "\(expected.count) events in five minutes")
    }

    @Test("The same made-up eyes at every run")
    func deterministic() {
        var a = DemoEyes(), b = DemoEyes()
        let times = (0..<900).map { 50 + Double($0) / 30 }
        #expect(times.map { a.reading(at: $0).closed } == times.map { b.reading(at: $0).closed })
    }

    @Test("The demo never writes to the user's own history")
    func demoKeepsItsDataApart() {
        let model = SampleData.demoModel()
        #expect(model.isDemo)
        #expect(model.history.store.file != HistoryStore.defaultFile)
        #expect(model.history.store.file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!model.history.minutes.isEmpty)
        #expect(!model.loginItem.available)
        #expect(!model.canCapture)
    }
}
