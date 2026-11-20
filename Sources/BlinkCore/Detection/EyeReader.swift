import Foundation
import CoreGraphics
import CoreVideo

// The first two stages of the pipeline, for one frame:
//
//     frame -> find the eyes (Vision) -> cut 64x64 pictures -> model: closed?
//              └────────── EyeFinder ──────────┘                └ EyeReader
//
// The recorder stops after EyeFinder (it saves the pictures); the monitor goes on with
// EyeReader. Both go through the SAME EyeFinder, which is what guarantees the model is
// asked about pictures made exactly like the ones it learned from.

/// One eye cut out of a frame.
public struct EyeCrop {
    public let region: EyeRegion
    /// The 64x64 picture, in the model's own format.
    public let picture: CVPixelBuffer
}

/// The eyes of one frame, found and cut out.
public struct FoundEyes {
    public let located: LocatedEyes
    /// One crop per usable eye that could be cut (an eye too near the frame's edge is missing).
    public let crops: [EyeCrop]

    /// Every usable eye was cut cleanly.
    public var isComplete: Bool {
        !crops.isEmpty && crops.count == located.usableEyes.count
    }
}

/// Finds the eyes in a frame and cuts them out, doing as little work as `FrameSchedule` allows.
public final class EyeFinder {

    public enum Outcome {
        /// The schedule skipped this frame (nobody has been there for a while).
        case skipped
        case noFace
        case found(FoundEyes)
    }

    private let locator = EyeLocator()
    private let cropper = EyeCropper()
    private var schedule = FrameSchedule()
    private var lastLocated: LocatedEyes?

    public init() {}

    /// `everyFrame`: search on this frame whatever the schedule says.
    /// The time spent is added to `cost`.
    public func find(in pixelBuffer: CVPixelBuffer, everyFrame: Bool = false, cost: inout FrameCost) throws -> Outcome {
        switch schedule.next(everyFrame: everyFrame) {
        case .skip:
            return .skipped
        case .search:
            lastLocated = try FrameCost.measure(into: &cost.findEyes) { try locator.locate(in: pixelBuffer) }
            schedule.searched(found: lastLocated != nil)
        case .reuseSquares:
            break
        }
        guard let located = lastLocated else { return .noFace }

        let crops = FrameCost.measure(into: &cost.crop) {
            located.usableEyes.compactMap { eye in
                cropper.cropBuffer(pixelBuffer, rect: eye.cropRect).map { EyeCrop(region: eye, picture: $0) }
            }
        }
        return .found(FoundEyes(located: located, crops: crops))
    }

    /// The whole frame, made smaller, for showing in a window.
    public func preview(_ pixelBuffer: CVPixelBuffer, maxWidth: CGFloat) -> CGImage? {
        cropper.preview(pixelBuffer, maxWidth: maxWidth)
    }
}

/// What the model said about one eye in one frame.
public struct EyeReading {
    public let side: EyeRegion.Side
    /// The 64x64 picture the model was given.
    public let picture: CVPixelBuffer
    /// The model's answer: probability that this eye is closed.
    public let closed: Double
    /// Vision's outline height / width (`EyeRegion.openness`): a second opinion.
    public let openness: Double

    public init(side: EyeRegion.Side, picture: CVPixelBuffer, closed: Double, openness: Double) {
        self.side = side
        self.picture = picture
        self.closed = closed
        self.openness = openness
    }
}

/// What one frame says about the eyes.
public struct FrameReading {
    public var faceFound = false
    /// The squares that were cut out, in frame pixels (for drawing over the camera picture).
    public var eyeRects: [CGRect] = []
    public var eyes: [EyeReading] = []
    /// The two eyes' answers combined into one (`EyeFusion`); nil when no eye was readable.
    public var closed: Double?

    public init() {}
}

/// Combines the answers of the two eyes into the one number the blink detector follows.
public enum EyeFusion {

    /// The average of the readable eyes.
    ///
    /// Both eyes blink together, so the two answers are two readings of the same event
    /// and averaging halves the noise of each. Its weakness is known and measured: when
    /// the model sees one eye close and misses the other (100% and 6%), the average lands
    /// near 50% and the blink can be lost.
    public static func combine(_ answers: [Double]) -> Double? {
        answers.isEmpty ? nil : answers.reduce(0, +) / Double(answers.count)
    }
}

/// Finds the eyes (through `EyeFinder`) and asks the model about each.
public final class EyeReader {

    private let finder = EyeFinder()
    private let classifier: EyeClassifier

    public init(classifier: EyeClassifier) {
        self.classifier = classifier
    }

    /// What this frame says about the eyes, and what reading it cost.
    /// Nil when the schedule skipped the frame.
    public func read(_ pixelBuffer: CVPixelBuffer, everyFrame: Bool = false) throws -> (reading: FrameReading, cost: FrameCost)? {
        var cost = FrameCost()
        var reading = FrameReading()
        let start = StageTimings.now()

        switch try finder.find(in: pixelBuffer, everyFrame: everyFrame, cost: &cost) {
        case .skipped:
            return nil
        case .noFace:
            break
        case .found(let found):
            reading.faceFound = true
            reading.eyeRects = found.located.usableEyes.map(\.cropRect)
            reading.eyes = try FrameCost.measure(into: &cost.model) {
                try found.crops.map { crop in
                    EyeReading(side: crop.region.side, picture: crop.picture,
                               closed: try classifier.closedProbability(of: crop.picture),
                               openness: Double(crop.region.openness))
                }
            }
            reading.closed = EyeFusion.combine(reading.eyes.map(\.closed))
        }
        cost.total = StageTimings.now() - start
        return (reading, cost)
    }

    /// The whole frame, made smaller, for showing in a window.
    public func preview(_ pixelBuffer: CVPixelBuffer, maxWidth: CGFloat) -> CGImage? {
        finder.preview(pixelBuffer, maxWidth: maxWidth)
    }
}
