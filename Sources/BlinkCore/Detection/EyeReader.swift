import Foundation
import CoreGraphics
import CoreVideo

// The first two stages of the pipeline, for one frame:
//
//     frame -> find the eyes (Vision) -> cut 64x64 pictures -> model: closed?
//              └────────── EyeFinder ──────────┘                └ EyeReader
//
// Recording a session stops after EyeFinder (it saves the pictures); counting goes on with
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
    /// This search found the eyes out of the squares that the frames before it read
    /// (`FrameSchedule.strayBeyond`): what those frames said was not about the eyes.
    public var strayed = false

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

    private let locator: EyeLocating
    private let cropper: EyeCropper
    private var schedule: FrameSchedule
    private var lastLocated: LocatedEyes?
    /// Frames in a row that read the squares of an earlier search.
    private var reused = 0

    /// The apps take the defaults. A replay passes its own to try another way of finding
    /// the eyes, another rhythm, or another way of cutting them out, on frames that were
    /// recorded (`CaptureReplay`).
    public init(locator: EyeLocating = EyeLocator(), schedule: FrameSchedule = FrameSchedule(),
                cropper: EyeCropper = EyeCropper()) {
        self.locator = locator
        self.schedule = schedule
        self.cropper = cropper
    }

    /// `everyFrame`: search on this frame whatever the schedule says.
    /// The time spent is added to `cost`.
    public func find(in pixelBuffer: CVPixelBuffer, everyFrame: Bool = false, cost: inout FrameCost) throws -> Outcome {
        var strayed = false
        switch schedule.next(everyFrame: everyFrame) {
        case .skip:
            return .skipped
        case .search:
            // Every frame read in full: nothing is taken from the frame before.
            if everyFrame { locator.forget() }
            let earlier = lastLocated
            lastLocated = try FrameCost.measure(into: &cost.findEyes) { try locator.locate(in: pixelBuffer) }
            schedule.searched(found: lastLocated != nil)
            // Frames have read the old squares since: were the eyes still in them?
            if reused > 0, let earlier, let now = lastLocated {
                strayed = schedule.strayed(moved: now.moved(since: earlier))
            }
            reused = 0
        case .reuseSquares:
            reused += 1
        }
        guard let located = lastLocated else { return .noFace }

        let crops = FrameCost.measure(into: &cost.crop) {
            located.usableEyes.compactMap { eye in
                cropper.cropBuffer(pixelBuffer, rect: eye.cropRect).map { EyeCrop(region: eye, picture: $0) }
            }
        }
        return .found(FoundEyes(located: located, crops: crops, strayed: strayed))
    }

    /// The whole frame, made smaller, for showing in a window.
    public func preview(_ pixelBuffer: CVPixelBuffer, maxWidth: CGFloat) -> CGImage? {
        cropper.preview(pixelBuffer, maxWidth: maxWidth)
    }
}

/// What the model said about one eye in one frame.
public struct EyeReading {
    public let side: EyeRegion.Side
    /// The 64x64 picture the model was given (nil for a reading that was made up: the demo).
    public let picture: CVPixelBuffer?
    /// The model's answer: probability that this eye is closed.
    public let closed: Double
    /// Vision's outline height / width (`EyeRegion.openness`): a second opinion.
    public let openness: Double

    public init(side: EyeRegion.Side, picture: CVPixelBuffer?, closed: Double, openness: Double) {
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
    /// The head is turned so far that only the eye nearest to the camera is read
    /// (`LocatedEyes.usableEyes`).
    public var headTurned = false
    /// The two eyes' answers combined into one (`EyeFusion`); nil when no eye was readable.
    public var closed: Double?
    /// Where the eyes were, from the squares this frame read: what the blink detector's
    /// rule 5 asks. Nil without a face, and for made-up readings (the demo).
    public var eyeLevel: EyeLevel?
    /// The frames before this one read squares the eyes had left (`FoundEyes.strayed`):
    /// what they said is to be forgotten. This frame's own answer is good.
    public var strayed = false

    public init() {}
}

extension BlinkDetector {
    /// Feed one frame's reading: its answer, after forgetting what came before when the
    /// frames before it did not read the eyes (`FrameReading.strayed`). A closure in
    /// progress is then dropped, like one that the face was lost in the middle of (the
    /// detector's rule 4): nobody knows what the eyes did.
    ///
    /// The counting rules themselves are not touched: this decides what they are fed.
    /// The Python copy (`training/detector.py`) has nothing to mirror, since it judges
    /// captures, whose eyes are searched on every frame: no square is ever old there.
    public mutating func update(time: Double, reading: FrameReading) -> Event? {
        if reading.strayed { reset() }
        return update(time: time, closed: reading.closed, eyes: reading.eyeLevel)
    }
}

extension EyeLevel {
    /// Both eyes, even when the head is turned and only one is read (`usableEyes`):
    /// Vision still places the far one, close enough to say where the head is, and the
    /// point between them does not jump when the near eye is read alone.
    public init(_ eyes: LocatedEyes) {
        self.init(height: Double(eyes.left.center.y + eyes.right.center.y) / 2,
                  apart: Double(eyes.interocularDistance))
    }
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

/// Anything that says how sure it is that the eye in a 64x64 picture is closed: the
/// trained model, or a stand-in when a test has no model.
public protocol EyeJudging {
    func closedProbability(of eye: CVPixelBuffer) throws -> Double
}

extension EyeClassifier: EyeJudging {}

/// Finds the eyes (through `EyeFinder`) and asks the model about each.
public final class EyeReader {

    private let finder: EyeFinder
    private let classifier: EyeJudging

    public init(classifier: EyeJudging, finder: EyeFinder = EyeFinder()) {
        self.classifier = classifier
        self.finder = finder
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
            reading.strayed = found.strayed
            reading.eyeRects = found.located.usableEyes.map(\.cropRect)
            reading.headTurned = found.located.usableEyes.count < found.located.eyes.count
            reading.eyes = try FrameCost.measure(into: &cost.model) {
                try found.crops.map { crop in
                    EyeReading(side: crop.region.side, picture: crop.picture,
                               closed: try classifier.closedProbability(of: crop.picture),
                               openness: Double(crop.region.openness))
                }
            }
            reading.closed = EyeFusion.combine(reading.eyes.map(\.closed))
            reading.eyeLevel = EyeLevel(found.located)
        }
        cost.total = StageTimings.now() - start
        return (reading, cost)
    }

    /// The whole frame, made smaller, for showing in a window.
    public func preview(_ pixelBuffer: CVPixelBuffer, maxWidth: CGFloat) -> CGImage? {
        finder.preview(pixelBuffer, maxWidth: maxWidth)
    }
}
