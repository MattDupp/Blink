import CoreGraphics
import CoreImage
import CoreVideo
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
        // The first version's way of making the picture: the same recipe, rendered with
        // createCGImage. It lives here, in the test, and nowhere in the shipped code.
        let recipe = try #require(cropper.recipe(for: noisy, rect: odd))
        let old = try #require(cropper.context.createCGImage(recipe, from: EyeCropper.outputRect,
                                                             format: .RGBA8, colorSpace: cropper.colorSpace))
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

    // MARK: Cut on the processor, as Core Image would

    /// How many of the colour values of two eye pictures differ, and by how much at most.
    private func gap(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (different: Int, largest: Int) {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let first = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let second = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let rowA = CVPixelBufferGetBytesPerRow(a), rowB = CVPixelBufferGetBytesPerRow(b)
        var different = 0, largest = 0
        for y in 0..<64 {
            for x in 0..<64 {
                for channel in 0..<4 {
                    let apart = abs(Int(first[y * rowA + x * 4 + channel]) - Int(second[y * rowB + x * 4 + channel]))
                    if apart > 0 { different += 1 }
                    largest = max(largest, apart)
                }
            }
        }
        return (different, largest)
    }

    /// A frame labelled as the Mac's camera labels its own (ITU-R 709): Core Image then
    /// converts the brightness, which is the case the app meets.
    private func cameraFrame() -> CVPixelBuffer {
        let frame = Fixture.frame(noise: true)
        CVBufferSetAttachment(frame, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return frame
    }

    /// The model learned from pictures Core Image cut. The pictures cut on the processor
    /// (`DirectCrop`) must be those pictures: on a frame of pure noise, the hardest there
    /// is to resize alike, no value may be more than one level of 255 away.
    @Test("An eye picture cut on the processor is Core Image's, to one level of 255",
          arguments: [40, 64, 90, 131, 147, 148, 200, 293, 294])
    func directCropMatchesCoreImage(side: Int) throws {
        let direct = EyeCropper(way: .direct), reference = EyeCropper(way: .coreImage)
        for frame in [Fixture.frame(noise: true), cameraFrame()] {
            for origin in [CGPoint(x: 701, y: 303), CGPoint(x: 1000, y: 500)] {
                let rect = CGRect(x: origin.x, y: origin.y, width: CGFloat(side), height: CGFloat(side))
                let a = try #require(direct.cropBuffer(frame, rect: rect)), b = try #require(reference.cropBuffer(frame, rect: rect))
                let apart = gap(a, b)
                #expect(apart.largest <= 1, "a square of \(side): a value is \(apart.largest) levels away")
                #expect(apart.different < 64 * 64 * 3 / 4, "a square of \(side): \(apart.different) of 12288 values differ")
            }
        }
    }

    @Test("Core Image halves a square from 148 pixels on, twice from 295")
    func halvings() {
        #expect([147, 148, 294, 295, 588, 589].map { EyeCropper.halvings(forSquare: CGFloat($0)) } == [0, 1, 1, 2, 2, 3])
    }

    /// What the direct way does not cut exactly as Core Image would, it hands to Core
    /// Image: the picture is then the same to the last number.
    @Test("A square halved twice, an enlarged one at the frame's edge, colours that are not the screen's: left to Core Image")
    func directCropHandsOver() throws {
        let direct = EyeCropper(way: .direct), reference = EyeCropper(way: .coreImage)
        let frame = cameraFrame()
        for rect in [CGRect(x: 700, y: 300, width: 300, height: 300), CGRect(x: 0, y: 0, width: 20, height: 20)] {
            let a = try #require(direct.cropBuffer(frame, rect: rect)), b = try #require(reference.cropBuffer(frame, rect: rect))
            #expect(gap(a, b).different == 0, "\(rect)")
        }
        // A camera whose colours are wider than the screen's: one curve per channel
        // cannot say what Core Image does with them.
        let wide = Fixture.frame(noise: true)
        CVBufferSetAttachment(wide, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(wide, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        #expect(ColourCurve.measure(like: wide, context: reference.context, colorSpace: reference.colorSpace) == nil)
        let rect = CGRect(x: 700, y: 300, width: 120, height: 120)
        let a = try #require(direct.cropBuffer(wide, rect: rect)), b = try #require(reference.cropBuffer(wide, rect: rect))
        #expect(gap(a, b).different == 0)
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

    // MARK: A face followed from one search to the next

    /// Eyes 100 pixels apart at (900, 500) and (1000, 500), top-left pixels.
    private func eyes(dx: CGFloat = 0, dy: CGFloat = 0, apart: CGFloat = 100) -> LocatedEyes {
        let left = CGPoint(x: 900 + dx, y: 500 + dy), right = CGPoint(x: 900 + dx + apart, y: 500 + dy)
        let rects = EyeLocator.cropRects(leftCenter: left, rightCenter: right)
        return LocatedEyes(faceRect: .zero,
                           left: EyeRegion(side: .imageLeft, cropRect: rects.left, center: left),
                           right: EyeRegion(side: .imageRight, cropRect: rects.right, center: right),
                           interocularDistance: rects.distance, roll: nil, yaw: nil)
    }

    @Test("Vision's boxes (fractions, from the bottom-left) become pixels from the top-left")
    func boxToPixels() {
        let box = EyeLocator.pixels(CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25), in: CGSize(width: 1920, height: 1080))
        #expect(box == CGRect(x: 480, y: 270, width: 480, height: 270))
    }

    @Test("Landmarks placed in a box are kept while they look like the face that was detected there")
    func stillThere() {
        // The face's box, and eyes that were 0.4 of its width apart when it was detected.
        let box = CGRect(x: 825, y: 380, width: 250, height: 250)
        #expect(EyeLocator.stillThere(eyes(), in: box, eyeDistanceShare: 0.4))
        #expect(EyeLocator.stillThere(eyes(dx: 30, dy: -20), in: box, eyeDistanceShare: 0.4))         // the head moved a little
        #expect(EyeLocator.stillThere(eyes(apart: 120), in: box, eyeDistanceShare: 0.4))             // leaned in a little

        #expect(!EyeLocator.stillThere(eyes(dx: 120), in: box, eyeDistanceShare: 0.4))               // an eye outside the box
        #expect(!EyeLocator.stillThere(eyes(apart: 60), in: box, eyeDistanceShare: 0.4))             // eyes far too close
        #expect(!EyeLocator.stillThere(eyes(dx: -40, apart: 140), in: box, eyeDistanceShare: 0.4))   // far too wide apart
        #expect(!EyeLocator.stillThere(eyes(), in: .zero, eyeDistanceShare: 0.4))
    }

    @Test("Between two detections the box moves with the eyes, and stays inside the picture")
    func boxFollowsTheEyes() {
        let size = CGSize(width: 1920, height: 1080)
        // Vision's units. The eyes of `eyes()` are at x = 950 of 1920, y = 500 of 1080 from the top.
        let box = CGRect(x: 0.43, y: 0.40, width: 0.13, height: 0.23)
        let middle = CGPoint(x: 950.0 / 1920, y: 1 - 500.0 / 1080)
        let eyesToCentre = CGPoint(x: (box.midX - middle.x) / box.width, y: (box.midY - middle.y) / box.height)

        // Eyes where they were: the box does not move.
        let same = EyeLocator.box(box, movedTo: eyes(), keeping: eyesToCentre, in: size)
        #expect(abs(same.minX - box.minX) < 1e-9 && abs(same.minY - box.minY) < 1e-9 && same.size == box.size)

        // Eyes 96 pixels to the right and 54 lower in the picture: so is the box
        // (0.05 of the width; 0.05 of the height DOWN, which is towards y = 0 for Vision).
        let moved = EyeLocator.box(box, movedTo: eyes(dx: 96, dy: 54), keeping: eyesToCentre, in: size)
        #expect(abs(moved.minX - (box.minX + 0.05)) < 1e-9 && abs(moved.minY - (box.minY - 0.05)) < 1e-9)

        // Eyes at the picture's edge: the box stops at the edge.
        let edge = EyeLocator.box(box, movedTo: eyes(dx: 900, dy: 0), keeping: eyesToCentre, in: size)
        #expect(edge.maxX <= 1 + 1e-9 && edge.minX >= 0)
    }

    /// Counts what the finder asks of it.
    private final class CountingLocator: EyeLocating {
        var searches = 0, forgets = 0
        func locate(in pixelBuffer: CVPixelBuffer) throws -> LocatedEyes? {
            searches += 1
            return nil
        }
        func forget() { forgets += 1 }
    }

    @Test("A frame read in full takes nothing from the frame before: the locator is told to forget")
    func everyFrameForgets() throws {
        let locator = CountingLocator()
        let finder = EyeFinder(locator: locator)
        var cost = FrameCost()
        let frame = Fixture.frame(width: 64, height: 64)
        for _ in 0..<3 { _ = try finder.find(in: frame, everyFrame: true, cost: &cost) }
        #expect(locator.searches == 3 && locator.forgets == 3)
        for _ in 0..<3 { _ = try finder.find(in: frame, cost: &cost) }
        #expect(locator.searches == 6 && locator.forgets == 3)
    }

    // MARK: Vision

    @Test("Vision runs on this Mac, and finds no face in a picture that has none", arguments: [
        EyeLocator.Strategy.wholeFrame, .faceBox(detectEvery: 8, follow: true),
    ])
    func noFaceInPaintedFrame(strategy: EyeLocator.Strategy) throws {
        let locator = EyeLocator(strategy: strategy)
        let frame = Fixture.frame(target: target)
        #expect(try locator.locate(in: frame) == nil)
        #expect(try locator.locate(in: frame) == nil)
        // No face was found, so there is no box to search in: both were whole-frame searches.
        #expect(locator.counts.wholeFrame == 2 && locator.counts.inBox == 0)
    }

    @Test("The apps look for the face on one search in 8, and move its box with the eyes in between")
    func usualStrategy() {
        #expect(EyeLocator().strategy == .faceBox(detectEvery: 8, follow: true))
    }
}
