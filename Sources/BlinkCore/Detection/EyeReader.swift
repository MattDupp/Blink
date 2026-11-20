import Foundation
import CoreGraphics
import CoreVideo

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

    /// How long each stage took for this frame, in seconds (see `StageTimings`).
    public var findEyesSeconds = 0.0
    public var cropSeconds = 0.0
    public var modelSeconds = 0.0
    public var totalSeconds = 0.0

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

/// Stages 1 and 2 of the pipeline, for one frame:
///
///     frame -> find the eyes (Vision) -> cut 64x64 pictures -> model: closed?
///              EyeLocator                EyeCropper            EyeClassifier
///
/// The recorder uses the first two steps to build the training pictures; the monitor uses
/// all three. The same code on both sides is what guarantees the model is asked about
/// pictures made exactly like the ones it learned from.
public final class EyeReader {

    private let locator = EyeLocator()
    private let cropper = EyeCropper()
    private let classifier: EyeClassifier

    public init(classifier: EyeClassifier) {
        self.classifier = classifier
    }

    public func read(_ pixelBuffer: CVPixelBuffer) throws -> FrameReading {
        var reading = FrameReading()
        let start = StageTimings.now()
        var cropTime = 0.0, modelTime = 0.0

        let located = try locator.locate(in: pixelBuffer)
        let afterLocate = StageTimings.now()

        if let located {
            reading.faceFound = true
            reading.eyeRects = located.usableEyes.map { $0.cropRect }
            for eye in located.usableEyes {
                let beforeCrop = StageTimings.now()
                guard let picture = cropper.cropBuffer(pixelBuffer, rect: eye.cropRect) else { continue }
                let beforeModel = StageTimings.now()
                let closed = try classifier.closedProbability(of: picture)
                let done = StageTimings.now()
                cropTime += beforeModel - beforeCrop
                modelTime += done - beforeModel
                reading.eyes.append(EyeReading(side: eye.side, picture: picture, closed: closed,
                                               openness: Double(eye.openness)))
            }
        }
        reading.closed = EyeFusion.combine(reading.eyes.map(\.closed))
        reading.findEyesSeconds = afterLocate - start
        reading.cropSeconds = cropTime
        reading.modelSeconds = modelTime
        reading.totalSeconds = StageTimings.now() - start
        return reading
    }

    /// The whole frame, made smaller, for showing in a window.
    public func preview(_ pixelBuffer: CVPixelBuffer, maxWidth: CGFloat) -> CGImage? {
        cropper.preview(pixelBuffer, maxWidth: maxWidth)
    }
}
