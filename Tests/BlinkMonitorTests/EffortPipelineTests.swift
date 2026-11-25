import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

@Suite("The effort, on the camera's thread")
struct EffortPipelineTests {

    /// Stands in for the model: every eye is open.
    private struct AlwaysOpen: EyeJudging {
        func closedProbability(of eye: CVPixelBuffer) throws -> Double { 0.02 }
    }

    /// A grey picture: no face in it.
    private func emptyFrame() -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &created)
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    @Test("Another effort takes over at the next frame; the frames keep being read and the counters are kept")
    func effortChanges() {
        let pipeline = MonitorPipeline(classifier: AlwaysOpen(), effort: .standard)
        var updates = 0
        pipeline.onUpdate = { _ in updates += 1 }
        let frame = emptyFrame()
        for index in 0..<3 { pipeline.process(frame, time: Double(index) / 30) }
        #expect(pipeline.effort == .standard)

        pipeline.setEffort(.light)
        #expect(pipeline.effort == .standard, "the camera's thread takes it in with its next frame")
        pipeline.process(frame, time: 3.0 / 30)
        #expect(pipeline.effort == .light)
        // Asking for the level already in force changes nothing; another one does.
        pipeline.setEffort(.light)
        pipeline.process(frame, time: 4.0 / 30)
        pipeline.setEffort(.thorough)
        for index in 5..<35 { pipeline.process(frame, time: Double(index) / 30) }
        #expect(pipeline.effort == .thorough)
        #expect(updates >= 1, "the heartbeat still goes out")
    }

    @Test("A pipeline that is handed readings, as in the demo, has no eyes to look for: the choice is taken in and changes nothing")
    func demoPipeline() {
        let pipeline = MonitorPipeline()
        pipeline.setEffort(.light)
        pipeline.process(FrameReading(), time: 0)
        #expect(pipeline.effort == .standard)
    }
}
