import CoreGraphics
import Testing
@testable import BlinkCore

@Suite("Finding and cropping the eyes")
struct VisionTests {

    // MARK: Geometry

    @Test("The crop is a square of 0.7 x the eye distance, centred on each eye")
    func cropSquares() {
        let rects = EyeLocator.cropRects(leftCenter: CGPoint(x: 800, y: 500), rightCenter: CGPoint(x: 900, y: 500))
        #expect(rects.distance == 100)
        #expect(rects.left.size == CGSize(width: 70, height: 70))
        #expect(rects.right.size == CGSize(width: 70, height: 70))
        #expect(rects.left.midX == 800 && rects.left.midY == 500)
        #expect(rects.right.midX == 900 && rects.right.midY == 500)
    }

    private func usableSides(yaw: Double?) -> String {
        let left = EyeRegion(side: .imageLeft, cropRect: .zero, center: CGPoint(x: 800, y: 500))
        let right = EyeRegion(side: .imageRight, cropRect: .zero, center: CGPoint(x: 900, y: 500))
        return LocatedEyes(faceRect: .zero, left: left, right: right, interocularDistance: 100, roll: nil, yaw: yaw)
            .usableEyes.map(\.side.rawValue).joined()
    }

    @Test("Head straight, or angle unknown: both eyes are used")
    func bothEyesWhenFacing() {
        #expect(usableSides(yaw: 0) == "LR")
        #expect(usableSides(yaw: nil) == "LR")
    }

    @Test("Head turned 45 degrees: only the eye nearest the camera is used")
    func nearEyeWhenTurned() {
        #expect(usableSides(yaw: 0.785) == "L")
        #expect(usableSides(yaw: -0.785) == "R")
    }

    // MARK: Cropping

    /// A square whose TOP half is red and BOTTOM half is blue: if the crop comes out upside
    /// down or from the wrong place (the classic top-left / bottom-left mix-up), the
    /// colours give it away.
    private let target = CGRect(x: 1000, y: 200, width: 128, height: 128)

    @Test("A crop is 64x64, the right way up, from the right place")
    func cropOrientation() throws {
        let cropper = EyeCropper()
        let crop = try #require(cropper.crop(Fixture.frame(target: target), rect: target))
        #expect(crop.width == EyeCropper.outputSize && crop.height == EyeCropper.outputSize)

        let top = Fixture.pixel(of: crop, x: 32, y: 8)
        let bottom = Fixture.pixel(of: crop, x: 32, y: 56)
        #expect(top.r > 200 && top.b < 60, "the top of the square must be red, got \(top)")
        #expect(bottom.b > 200 && bottom.r < 60, "the bottom of the square must be blue, got \(bottom)")
    }

    @Test("A square partly outside the frame is refused")
    func cropOutsideFrame() {
        let cropper = EyeCropper()
        #expect(cropper.crop(Fixture.frame(), rect: CGRect(x: 1900, y: 10, width: 64, height: 64)) == nil)
    }

    /// The model was trained on pictures made by the first version's `createCGImage`.
    /// The pixel-buffer path that replaced it (74 times cheaper to hand to Core ML) must
    /// give the same pixels - on a frame with detail at every scale, and a square whose
    /// size is not a round multiple of 64.
    @Test("The pixel-buffer crop gives the pixels the model was trained on")
    func cropMatchesTrainingPath() throws {
        let cropper = EyeCropper()
        let noisy = Fixture.frame(noise: true)
        let odd = CGRect(x: 700, y: 300, width: 131, height: 131)
        let old = try #require(cropper.legacyCrop(noisy, rect: odd))
        let new = try #require(cropper.crop(noisy, rect: odd))

        var worst = 0
        for y in stride(from: 0, to: 64, by: 3) {
            for x in stride(from: 0, to: 64, by: 3) {
                let a = Fixture.pixel(of: old, x: x, y: y), b = Fixture.pixel(of: new, x: x, y: y)
                worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            }
        }
        #expect(worst <= 1, "largest difference \(worst) of 255")
    }

    @Test("A picture copied into a pixel buffer and back is unchanged")
    func bufferRoundTrip() throws {
        let cropper = EyeCropper()
        let original = try #require(cropper.crop(Fixture.frame(noise: true), rect: CGRect(x: 100, y: 100, width: 90, height: 90)))
        let buffer = try #require(EyeCropper.buffer(from: original))
        let copy = try #require(EyeCropper.image(from: buffer))
        for (x, y) in [(0, 0), (17, 40), (63, 63), (31, 5)] {
            let a = Fixture.pixel(of: original, x: x, y: y), b = Fixture.pixel(of: copy, x: x, y: y)
            #expect(a.r == b.r && a.g == b.g && a.b == b.b)
        }
    }

    @Test("The window preview keeps the frame's shape")
    func previewSize() throws {
        let preview = try #require(EyeCropper().preview(Fixture.frame(), maxWidth: 960))
        #expect(preview.width == 960 && preview.height == 540)
    }

    // MARK: Vision

    @Test("Vision runs on this Mac, and finds no face in a picture that has none")
    func noFaceInPaintedFrame() throws {
        #expect(try EyeLocator().locate(in: Fixture.frame(target: target)) == nil)
    }
}
