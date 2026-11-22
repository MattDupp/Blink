import Vision
import CoreGraphics
import CoreVideo

/// One eye found in a frame.
public struct EyeRegion {
    /// Which eye, named by where it is IN THE PICTURE (not "the person's left eye"):
    /// what the model sees is the picture, and in the picture the nose is on the right
    /// of the image-left eye. Training uses this to flip one side so both eyes look alike.
    public enum Side: String {
        case imageLeft = "L"
        case imageRight = "R"
    }

    public let side: Side
    /// The square to cut out, in pixels, origin at the TOP-left of the frame.
    public let cropRect: CGRect
    /// The centre of the eye, same coordinates.
    public let center: CGPoint
    /// Height of Vision's eye outline divided by its width: roughly 0.3 for an open eye,
    /// smaller as the lid comes down. It is a second opinion on the eyelid, obtained
    /// without our model - recorded with the captures to help label real blinks.
    /// It is NOT used to count blinks.
    public let openness: CGFloat

    public init(side: Side, cropRect: CGRect, center: CGPoint, openness: CGFloat = 0) {
        self.side = side
        self.cropRect = cropRect
        self.center = center
        self.openness = openness
    }
}

/// The eyes of the face nearest to the camera.
public struct LocatedEyes {
    /// The face's bounding box, in pixels, origin top-left.
    public let faceRect: CGRect
    public let left: EyeRegion   // the eye on the left of the picture
    public let right: EyeRegion  // the eye on the right of the picture
    /// Distance between the two eye centres, in pixels: our measure of how big the face is.
    public let interocularDistance: CGFloat
    /// Head angles in radians, when Vision gives them (roll = tilt towards a shoulder,
    /// yaw = turn left / right). Saved with the data so we can later ask
    /// "does the model fail when the head is turned?".
    public let roll: Double?
    public let yaw: Double?

    public var eyes: [EyeRegion] { [left, right] }

    /// Beyond this head turn (radians) only the eye nearest to the camera is trusted.
    public static let maxYawForBothEyes = 0.4

    /// The eyes worth looking at. When the head is turned far to one side, the far eye
    /// hides behind the nose and Vision's point for it lands on the nose or the cheek.
    ///
    /// SEEN IN THE FIRST RECORDED SESSION (2026-11-20, pose "turned"): Vision reported a
    /// yaw of +0.785 (it only reports steps of 45 degrees) and the image-right crops showed
    /// the profile of the nose, saved as "closed eye". The image-left eye stayed good.
    /// A negative yaw is taken to be the mirror case; it has not been observed yet.
    public var usableEyes: [EyeRegion] {
        guard let yaw, abs(yaw) > Self.maxYawForBothEyes else { return [left, right] }
        return yaw > 0 ? [left] : [right]
    }

    public init(faceRect: CGRect, left: EyeRegion, right: EyeRegion, interocularDistance: CGFloat,
                roll: Double?, yaw: Double?) {
        self.faceRect = faceRect
        self.left = left
        self.right = right
        self.interocularDistance = interocularDistance
        self.roll = roll
        self.yaw = yaw
    }
}

/// Anything that finds the eyes in a frame: Apple's Vision in the apps (`EyeLocator`),
/// or a stand-in that knows where they were painted when a test has no face to show.
public protocol EyeLocating {
    /// The eyes of the face nearest to the camera, or nil when no face is seen.
    func locate(in pixelBuffer: CVPixelBuffer) throws -> LocatedEyes?
    /// Forget where the face was: the next search starts from nothing.
    func forget()
}

extension EyeLocating {
    public func forget() {}
}

/// Finds where the eyes are in a frame.
///
/// This is STAGE 1 of the pipeline, and we do not train it: Apple's Vision framework ships
/// a face-landmark network (it places about 76 points on a face - eyes, brows, nose, lips)
/// that runs on this Mac. Our own model is STAGE 2: it only has to answer "is this small
/// eye picture open or closed?" - a far easier problem than "find a blink in a whole
/// 1920x1080 frame", and one a small network can learn from a few thousand pictures.
public final class EyeLocator: EyeLocating {

    /// The crop is a square whose side is this fraction of the distance between the eyes.
    ///
    /// Why the distance between the eyes and not the eye's own outline? The outline
    /// collapses when the eye closes and jitters from frame to frame; the two eye centres
    /// are each an average of several points and stay put. 0.7 x that distance (about
    /// 44 mm on an adult face) frames the eye, its lids and a little of the brow.
    public static let cropScale: CGFloat = 0.7

    /// How a search finds the eyes.
    public enum Strategy: Equatable {
        /// Find the face in the whole frame, then place the landmarks on it: every search.
        case wholeFrame
        /// Find the face in the whole frame on one search in `detectEvery`. In between,
        /// place the landmarks in the box where the face was: Vision is handed that box
        /// (`inputFaceObservations`) and skips looking for faces.
        ///
        /// `follow`: between two detections, move the box with the eyes it finds.
        case faceBox(detectEvery: Int, follow: Bool)
    }

    /// How the searches went, for judging a strategy (`CaptureReplay`).
    public struct Counts: Equatable {
        /// Searches of the whole frame.
        public var wholeFrame = 0
        /// Searches in the box where the face was, that were kept.
        public var inBox = 0
        /// Searches in the box whose landmarks did not look like the face that was
        /// there: the whole frame was searched after all.
        public var doubted = 0
        /// Seconds spent in Vision by the searches of the whole frame, and by the
        /// searches in the box (kept or doubted).
        public var wholeFrameSeconds = 0.0
        public var inBoxSeconds = 0.0

        public init() {}
    }

    public let strategy: Strategy
    public private(set) var counts = Counts()

    /// Finds faces, then their landmarks.
    private let request = VNDetectFaceLandmarksRequest()
    /// Places landmarks on faces it is given.
    private let inBoxRequest = VNDetectFaceLandmarksRequest()
    private var known: KnownFace?

    /// The face found by the last search of the whole frame.
    struct KnownFace {
        /// Vision's own units: fractions of the picture, measured from the BOTTOM-left.
        var box: CGRect
        /// Vision gives the head's angles with the face it detects, not with landmarks
        /// placed in a box: they are the detection's until the next one.
        let roll: Double?
        let yaw: Double?
        /// Eye distance / box width when the face was detected: what the landmarks of
        /// the same face should keep giving.
        let eyeDistanceShare: CGFloat
        /// From the middle of the eyes to the middle of the box, in box widths and heights.
        let eyesToCentre: CGPoint
        /// Searches made in this box since the detection.
        var searches = 0
    }

    /// What the apps use: the face is looked for on one search in 8 (about twice a second,
    /// with a search every other frame), and its box follows the eyes in between.
    ///
    /// WHY NOT THE WHOLE FRAME EVERY TIME. A profile of the running app (2026-11-20) showed
    /// that finding the FACE is about half of a search, and almost none of that half is the
    /// network: it is Vision shrinking the 1920x1080 frame for its detector. Handed the box,
    /// Vision skips it.
    ///
    /// MEASURED on three captures replayed from their whole frames (`make replay`, 121 s,
    /// 80 blinks marked): the blinks counted are those counted when the whole frame is
    /// searched on every frame, plus one real blink that way misses. A search in the box
    /// took 3.5 ms where a search of the whole frame took 5.1 to 6.1 ms.
    ///
    /// MEASURED IN THE APP (2026-11-22, the same build started six times, turn about, with
    /// and without `--eye-search=whole-frame`, three and a half minutes each): finding the
    /// eyes went from 10.7 to 5.2 ms a frame in the app's log, a whole frame from 14.7 to
    /// 9.4 ms, and the app from 39% to 32% of one core.
    ///
    /// WHY 8 AND NOT MORE. With one detection in 8 searches the detections are already an
    /// eighth of the work; one in 30 would save 3% more, and the head's angles (which
    /// decide whether the far eye is read) would be two seconds old instead of half a one.
    public static let usual = Strategy.faceBox(detectEvery: 8, follow: true)

    public init(strategy: Strategy = EyeLocator.usual) {
        self.strategy = strategy
    }

    public func forget() {
        known = nil
    }

    /// Returns the eyes of the largest face, or nil when no face (or no usable eye) is seen.
    public func locate(in pixelBuffer: CVPixelBuffer) throws -> LocatedEyes? {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        if case .faceBox(let detectEvery, let follow) = strategy, var face = known, face.searches + 1 < detectEvery {
            if let eyes = try locate(in: face, handler: handler, size: size) {
                face.searches += 1
                if follow { face.box = Self.box(face.box, movedTo: eyes, keeping: face.eyesToCentre, in: size) }
                known = face
                counts.inBox += 1
                return eyes
            }
            counts.doubted += 1
        }
        return try locateInWholeFrame(handler: handler, size: size)
    }

    /// Finds the face, then its eyes; remembers the face for the searches that follow.
    private func locateInWholeFrame(handler: VNImageRequestHandler, size: CGSize) throws -> LocatedEyes? {
        counts.wholeFrame += 1
        known = nil
        try FrameCost.measure(into: &counts.wholeFrameSeconds) { try handler.perform([request]) }

        // Several faces (someone behind you)? Keep the largest: the one at the keyboard.
        guard let face = (request.results ?? []).max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }
        guard let eyes = Self.eyes(of: face, roll: face.roll?.doubleValue, yaw: face.yaw?.doubleValue, size: size) else { return nil }

        let box = face.boundingBox
        if box.width > 0, box.height > 0 {
            let middle = Self.middleOfEyes(eyes, in: size)
            known = KnownFace(box: box, roll: eyes.roll, yaw: eyes.yaw,
                              eyeDistanceShare: eyes.interocularDistance / (box.width * size.width),
                              eyesToCentre: CGPoint(x: (box.midX - middle.x) / box.width, y: (box.midY - middle.y) / box.height))
        }
        return eyes
    }

    /// Places the landmarks in the box where the face was. Nil when what comes back does
    /// not look like that face any more (`stillThere`).
    private func locate(in face: KnownFace, handler: VNImageRequestHandler, size: CGSize) throws -> LocatedEyes? {
        // A NEW observation each time, holding the box and nothing else. Apple's header:
        // observations given "without the landmarks property populated" get landmarks;
        // one that already has them is "returned" as it is. Handing back the previous
        // result would freeze the eyes where they were.
        inBoxRequest.inputFaceObservations = [VNFaceObservation(boundingBox: face.box)]
        try FrameCost.measure(into: &counts.inBoxSeconds) { try handler.perform([inBoxRequest]) }
        guard let placed = inBoxRequest.results?.first,
              let eyes = Self.eyes(of: placed, roll: face.roll, yaw: face.yaw, size: size) else { return nil }
        let box = Self.pixels(face.box, in: size)
        return Self.stillThere(eyes, in: box, eyeDistanceShare: face.eyeDistanceShare) ? eyes : nil
    }

    // MARK: - From Vision's landmarks to eye squares

    /// The eyes of a face Vision has placed its landmarks on.
    private static func eyes(of face: VNFaceObservation, roll: Double?, yaw: Double?, size: CGSize) -> LocatedEyes? {
        let width = size.width, height = size.height
        guard let landmarks = face.landmarks,
              let eyeA = landmarks.leftEye, let eyeB = landmarks.rightEye,
              let centerA = Self.center(of: eyeA, width: width, height: height),
              let centerB = Self.center(of: eyeB, width: width, height: height) else { return nil }

        // Vision's own "left" / "right" names are not used: we sort by position in the picture.
        let aIsLeft = centerA.x <= centerB.x
        let (leftCenter, rightCenter) = aIsLeft ? (centerA, centerB) : (centerB, centerA)
        let opennessA = Self.openness(of: eyeA, width: width, height: height)
        let opennessB = Self.openness(of: eyeB, width: width, height: height)
        let (leftOpenness, rightOpenness) = aIsLeft ? (opennessA, opennessB) : (opennessB, opennessA)
        let rects = Self.cropRects(leftCenter: leftCenter, rightCenter: rightCenter)

        return LocatedEyes(
            faceRect: pixels(face.boundingBox, in: size),
            left: EyeRegion(side: .imageLeft, cropRect: rects.left, center: leftCenter, openness: leftOpenness),
            right: EyeRegion(side: .imageRight, cropRect: rects.right, center: rightCenter, openness: rightOpenness),
            interocularDistance: rects.distance,
            roll: roll, yaw: yaw)
    }

    /// Vision measures from the BOTTOM-left, in fractions of the picture. The same box
    /// in pixels from the top-left, like everything else here.
    static func pixels(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }

    /// The point half-way between the eyes, in Vision's units.
    private static func middleOfEyes(_ eyes: LocatedEyes, in size: CGSize) -> CGPoint {
        CGPoint(x: (eyes.left.center.x + eyes.right.center.x) / 2 / size.width,
                y: 1 - (eyes.left.center.y + eyes.right.center.y) / 2 / size.height)
    }

    // MARK: - A box that was not checked

    /// How far the eye distance may drift from what the detection gave before the
    /// landmarks are doubted (a factor, either way).
    static let eyeDistanceTolerance: CGFloat = 1.3

    /// Do landmarks placed in a box still look like the face that was detected in it?
    ///
    /// Vision places its landmarks wherever it is told to, face or no face: handed the
    /// box of someone who has just left, it draws eyes on the wall. Two things a real
    /// face in its box keeps: both eyes are inside it, and they are as far apart,
    /// measured in box widths, as when the face was detected.
    ///
    /// SEEN on a recorded capture (2026-11-20) in which the person leans out of view:
    /// with the face in its box the eye distance stayed within 1% of the detection's;
    /// three frames after the face had gone it was 0.6 of it, then 0.1 for as long as
    /// the box showed the wall. (Vision's own confidence in its landmarks only went from
    /// 0.9 to 0.7: it is not what gives the wall away.)
    /// Everything in pixels from the top-left.
    static func stillThere(_ eyes: LocatedEyes, in box: CGRect, eyeDistanceShare: CGFloat) -> Bool {
        guard box.width > 0, eyeDistanceShare > 0,
              box.contains(eyes.left.center), box.contains(eyes.right.center) else { return false }
        let drift = eyes.interocularDistance / box.width / eyeDistanceShare
        return drift < eyeDistanceTolerance && drift > 1 / eyeDistanceTolerance
    }

    /// The box moved so that the eyes sit in it where they sat when the face was
    /// detected, and kept inside the picture. Vision's units.
    static func box(_ box: CGRect, movedTo eyes: LocatedEyes, keeping eyesToCentre: CGPoint, in size: CGSize) -> CGRect {
        let middle = middleOfEyes(eyes, in: size)
        var moved = box
        moved.origin.x = middle.x + eyesToCentre.x * box.width - box.width / 2
        moved.origin.y = middle.y + eyesToCentre.y * box.height - box.height / 2
        moved.origin.x = min(max(moved.origin.x, 0), max(0, 1 - box.width))
        moved.origin.y = min(max(moved.origin.y, 0), max(0, 1 - box.height))
        return moved
    }

    /// The two squares to cut out, from the two eye centres. Pure arithmetic, kept apart
    /// so the self-test can check it without a camera or a face.
    public static func cropRects(leftCenter: CGPoint, rightCenter: CGPoint)
        -> (left: CGRect, right: CGRect, distance: CGFloat) {
        let distance = hypot(rightCenter.x - leftCenter.x, rightCenter.y - leftCenter.y)
        let side = (distance * cropScale).rounded()
        func square(around c: CGPoint) -> CGRect {
            CGRect(x: (c.x - side / 2).rounded(), y: (c.y - side / 2).rounded(), width: side, height: side)
        }
        return (square(around: leftCenter), square(around: rightCenter), distance)
    }

    /// Height / width of the box around the points Vision placed on the eye's outline.
    private static func openness(of region: VNFaceLandmarkRegion2D, width: CGFloat, height: CGFloat) -> CGFloat {
        let points = region.pointsInImage(imageSize: CGSize(width: width, height: height))
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX else { return 0 }
        return (maxY - minY) / (maxX - minX)
    }

    /// The centre of an eye = the average of the points Vision placed around it,
    /// converted to pixels measured from the top-left.
    private static func center(of region: VNFaceLandmarkRegion2D, width: CGFloat, height: CGFloat) -> CGPoint? {
        let points = region.pointsInImage(imageSize: CGSize(width: width, height: height))
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let n = CGFloat(points.count)
        // pointsInImage measures y from the bottom: flip it.
        return CGPoint(x: sum.x / n, y: height - sum.y / n)
    }
}
