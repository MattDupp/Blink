import CoreImage
import CoreGraphics
import CoreVideo

/// Cuts a square out of a frame and resizes it to the small fixed size the model takes.
///
/// A neural network needs every input to have the same shape. Your face moves nearer and
/// farther, so the eye covers 60 pixels one minute and 110 the next; resizing every crop
/// to 64x64 removes "how far is the face" from the problem before the model sees it.
public final class EyeCropper {

    /// Side of the saved picture, in pixels. Open / closed is readable at 32x32; we keep
    /// 64x64 so training can shift and zoom the pictures a little (augmentation) and still
    /// have real pixels to show the model.
    public static let outputSize = 64

    // Core Image runs these operations on the GPU. A context is expensive to create and
    // cheap to reuse, so there is one for the whole life of the cropper.
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {
        context = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
    }

    /// `rect` is in pixels, origin top-left (as `EyeLocator` gives it).
    /// Returns nil when the square is not entirely inside the frame: a half-cut eye
    /// would teach the model something that never happens in a good frame.
    public func crop(_ pixelBuffer: CVPixelBuffer, rect: CGRect) -> CGImage? {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard rect.width >= 8, CGRect(x: 0, y: 0, width: width, height: height).contains(rect) else { return nil }

        // Core Image measures y from the BOTTOM of the picture, we measure from the top.
        let bottomUp = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        let scale = CGFloat(Self.outputSize) / rect.width

        // Move the square to the origin, then scale it to 64x64. Nothing is computed yet:
        // a CIImage is a recipe. `createCGImage` runs it, and only for the 64x64 region
        // we ask for - the rest of the frame is never touched.
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(translationX: -bottomUp.minX, y: -bottomUp.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let size = CGFloat(Self.outputSize)
        return context.createCGImage(image, from: CGRect(x: 0, y: 0, width: size, height: size),
                                     format: .RGBA8, colorSpace: colorSpace)
    }

    /// The whole frame, made smaller, for showing on screen.
    public func preview(_ pixelBuffer: CVPixelBuffer, maxWidth: CGFloat) -> CGImage? {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let scale = min(1, maxWidth / width)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(image,
                                     from: CGRect(x: 0, y: 0, width: (width * scale).rounded(.down),
                                                  height: (height * scale).rounded(.down)),
                                     format: .RGBA8, colorSpace: colorSpace)
    }
}
