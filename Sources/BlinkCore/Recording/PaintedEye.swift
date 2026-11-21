import CoreGraphics
import CoreVideo
import Foundation

/// An eye that does not exist: a drawing of one, 64x64, in the form the camera's own eye
/// pictures have.
///
/// Two uses, and the reason is the same for both: the whole chain from a picture to a
/// counted blink can then run with no camera and nobody's face.
///   - The demo's setup records painted sessions, really trains a model on them and really
///     tests it (`PaintedCamera` in the app).
///   - The tests give the trainer a task whose right answer is known.
///
/// A drawing is far easier to tell open from closed than a real eye. What it proves is
/// that the machinery works, never how well a model reads a person.
public struct PaintedEye: Equatable {

    /// 1 = wide open, 0 = closed.
    public var openness = 1.0
    /// Where the eye sits, in pixels from the middle of the picture.
    public var offset = CGPoint.zero
    /// 1 = the usual size; a face further away gives a smaller eye.
    public var scale = 1.0
    /// The head tilted towards a shoulder, in radians.
    public var tilt = 0.0
    /// How bright the skin is: 0 = black, 1 = white.
    public var light = 0.7
    /// Where the eye looks: -1...1 across, -1...1 up and down (positive = down).
    public var gaze = CGPoint.zero
    /// The eye on the left of a picture has the nose on its right.
    public var noseOnRight = true

    public init(openness: Double = 1, offset: CGPoint = .zero, scale: Double = 1, tilt: Double = 0, light: Double = 0.7,
                gaze: CGPoint = .zero, noseOnRight: Bool = true) {
        self.openness = openness
        self.offset = offset
        self.scale = scale
        self.tilt = tilt
        self.light = light
        self.gaze = gaze
        self.noseOnRight = noseOnRight
    }

    /// An eye with every setting drawn at random: for a set of pictures that differ.
    public static func random(open: Bool, using random: inout SeededRandom) -> PaintedEye {
        PaintedEye(openness: open ? Double(random.uniform(0.45, 1)) : 0,
                   offset: CGPoint(x: Double(random.uniform(-5, 5)), y: Double(random.uniform(-4, 4))),
                   scale: Double(random.uniform(0.8, 1.2)), tilt: Double(random.uniform(-0.3, 0.3)),
                   light: Double(random.uniform(0.4, 0.85)),
                   gaze: CGPoint(x: Double(random.uniform(-0.8, 0.8)), y: Double(random.uniform(-0.6, 0.6))),
                   noseOnRight: random.uniform() < 0.5)
    }

    /// The drawing, as a 64x64 BGRA pixel buffer.
    public func buffer() -> CVPixelBuffer? {
        let side = EyeCropper.outputSize
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attributes, &created)
        guard let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let layout = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layout) else { return nil }
        draw(in: context, side: CGFloat(side))
        return buffer
    }

    /// The drawing, as an image (to show it, or to save it as a session's picture).
    public func image() -> CGImage? {
        buffer().flatMap(EyeCropper.image(from:))
    }

    private func draw(in context: CGContext, side: CGFloat) {
        // Core Graphics counts y from the bottom; the drawing below counts from the top.
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)

        func shade(_ level: Double, warm: Double = 1) -> CGColor {
            let value = min(max(level, 0), 1)
            return CGColor(srgbRed: value, green: value * (1 - 0.16 * warm), blue: value * (1 - 0.27 * warm), alpha: 1)
        }
        context.setFillColor(shade(light))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        // The side of the nose: a darker band on one edge.
        context.setFillColor(shade(light * 0.86))
        context.fill(CGRect(x: noseOnRight ? side - 7 : 0, y: 20, width: 7, height: side - 20))

        let centre = CGPoint(x: side / 2 + offset.x, y: side / 2 + 4 + offset.y)
        context.translateBy(x: centre.x, y: centre.y)
        context.rotate(by: tilt)
        context.scaleBy(x: scale, y: scale)

        // The eyebrow.
        context.setStrokeColor(shade(light * 0.32))
        context.setLineWidth(4)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: -22, y: -19))
        context.addQuadCurve(to: CGPoint(x: 22, y: -19), control: CGPoint(x: 0, y: -27))
        context.strokePath()

        let half = 20.0
        if openness > 0.1 {
            // An almond: the upper lid arches more than the lower one.
            let up = 15.0 * openness, down = 10.0 * openness
            let almond = CGMutablePath()
            almond.move(to: CGPoint(x: -half, y: 0))
            almond.addQuadCurve(to: CGPoint(x: half, y: 0), control: CGPoint(x: 0, y: -up * 2))
            almond.addQuadCurve(to: CGPoint(x: -half, y: 0), control: CGPoint(x: 0, y: down * 2))
            context.saveGState()
            context.addPath(almond)
            context.clip()
            context.setFillColor(shade(min(light + 0.25, 0.97), warm: 0.2))
            context.fill(CGRect(x: -half, y: -30, width: half * 2, height: 60))
            let iris = CGPoint(x: gaze.x * 7, y: gaze.y * 4)
            context.setFillColor(shade(light * 0.38, warm: 1.6))
            context.fillEllipse(in: CGRect(x: iris.x - 9, y: iris.y - 9, width: 18, height: 18))
            context.setFillColor(shade(0.04))
            context.fillEllipse(in: CGRect(x: iris.x - 4, y: iris.y - 4, width: 8, height: 8))
            context.setFillColor(shade(0.95, warm: 0))
            context.fillEllipse(in: CGRect(x: iris.x + 1.5, y: iris.y - 4.5, width: 3, height: 3))
            context.restoreGState()

            context.setStrokeColor(shade(light * 0.22))
            context.setLineWidth(2.4)
            context.move(to: CGPoint(x: -half, y: 0))
            context.addQuadCurve(to: CGPoint(x: half, y: 0), control: CGPoint(x: 0, y: -up * 2))
            context.strokePath()
            context.setStrokeColor(shade(light * 0.6))
            context.setLineWidth(1)
            context.move(to: CGPoint(x: -half, y: 0))
            context.addQuadCurve(to: CGPoint(x: half, y: 0), control: CGPoint(x: 0, y: down * 2))
            context.strokePath()
        } else {
            // Closed: the lid's edge, its lashes pointing down, and the fold above it.
            context.setStrokeColor(shade(light * 0.22))
            context.setLineWidth(2.6)
            context.move(to: CGPoint(x: -half, y: 0))
            context.addQuadCurve(to: CGPoint(x: half, y: 0), control: CGPoint(x: 0, y: 9))
            context.strokePath()
            context.setLineWidth(1.2)
            for step in -3...3 {
                let x = Double(step) * 5.5, y = 4.4 - 0.36 * Double(step * step)
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x * 1.12, y: y + 4.5))
            }
            context.strokePath()
            context.setStrokeColor(shade(light * 0.7))
            context.setLineWidth(1)
            context.move(to: CGPoint(x: -half + 3, y: -6))
            context.addQuadCurve(to: CGPoint(x: half - 3, y: -6), control: CGPoint(x: 0, y: -13))
            context.strokePath()
        }
    }
}
