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

/// Finds where the eyes are in a frame.
///
/// This is STAGE 1 of the pipeline, and we do not train it: Apple's Vision framework ships
/// a face-landmark network (it places about 76 points on a face - eyes, brows, nose, lips)
/// that runs on this Mac. Our own model is STAGE 2: it only has to answer "is this small
/// eye picture open or closed?" - a far easier problem than "find a blink in a whole
/// 1920x1080 frame", and one a small network can learn from a few thousand pictures.
public final class EyeLocator {

    /// The crop is a square whose side is this fraction of the distance between the eyes.
    ///
    /// Why the distance between the eyes and not the eye's own outline? The outline
    /// collapses when the eye closes and jitters from frame to frame; the two eye centres
    /// are each an average of several points and stay put. 0.7 x that distance (about
    /// 44 mm on an adult face) frames the eye, its lids and a little of the brow.
    public static let cropScale: CGFloat = 0.7

    private let request = VNDetectFaceLandmarksRequest()

    public init() {}

    /// Returns the eyes of the largest face, or nil when no face (or no usable eye) is seen.
    public func locate(in pixelBuffer: CVPixelBuffer) throws -> LocatedEyes? {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        // Several faces (someone behind you)? Keep the largest: the one at the keyboard.
        guard let face = (request.results ?? []).max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }

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

        // Vision measures from the BOTTOM-left, in fractions of the picture. Convert the
        // face box to pixels from the top-left like everything else here.
        let box = face.boundingBox
        let faceRect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                              width: box.width * width, height: box.height * height)

        return LocatedEyes(
            faceRect: faceRect,
            left: EyeRegion(side: .imageLeft, cropRect: rects.left, center: leftCenter, openness: leftOpenness),
            right: EyeRegion(side: .imageRight, cropRect: rects.right, center: rightCenter, openness: rightOpenness),
            interocularDistance: rects.distance,
            roll: face.roll?.doubleValue,
            yaw: face.yaw?.doubleValue)
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
