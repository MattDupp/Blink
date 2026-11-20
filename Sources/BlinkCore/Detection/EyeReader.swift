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

/// Decides on which frames the eyes are searched for again.
///
/// MEASURED in the running app (2026-11-20, performance.csv): finding the eyes with Vision
/// takes 12 to 15 ms per frame, cutting and classifying them 2 ms. But eyes do not move
/// far in a thirtieth of a second: the squares found on one frame still frame the eyes on
/// the next. So the search runs every other frame, and the frame in between reads the
/// same squares - every frame is still classified, which is what catching a blink needs.
///
/// As soon as a search finds no face, the next frame searches again: stale squares are
/// never kept for more than one frame.
public struct LocateSchedule {

    /// Search for the eyes on one frame in this many.
    public var every: Int

    private var framesSinceSearch = 0
    private var haveEyes = false

    public init(every: Int = 2) {
        self.every = max(1, every)
    }

    /// Call once per frame, before deciding. True = search now.
    public mutating func shouldSearch() -> Bool {
        guard haveEyes, framesSinceSearch + 1 < every else { return true }
        framesSinceSearch += 1
        return false
    }

    /// Call after a search, with whether it found the eyes.
    public mutating func searched(found: Bool) {
        haveEyes = found
        framesSinceSearch = 0
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
    private var schedule = LocateSchedule()
    private var lastLocated: LocatedEyes?

    public init(classifier: EyeClassifier) {
        self.classifier = classifier
    }

    /// `searchEveryFrame`: find the eyes again on this frame whatever the schedule says
    /// (a capture wants Vision's outline on every frame).
    public func read(_ pixelBuffer: CVPixelBuffer, searchEveryFrame: Bool = false) throws -> FrameReading {
        var reading = FrameReading()
        let start = StageTimings.now()
        var cropTime = 0.0, modelTime = 0.0

        if schedule.shouldSearch() || searchEveryFrame {
            lastLocated = try locator.locate(in: pixelBuffer)
            schedule.searched(found: lastLocated != nil)
        }
        let located = lastLocated
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
