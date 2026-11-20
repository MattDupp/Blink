import CoreImage
import CoreGraphics
import CoreVideo

/// Cuts a square out of a frame and resizes it to the small fixed size the model takes.
///
/// A neural network needs every input to have the same shape. Your face moves nearer and
/// farther, so the eye covers 60 pixels one minute and 110 the next; resizing every crop
/// to 64x64 removes "how far is the face" from the problem before the model sees it.
public final class EyeCropper {

    /// Side of the eye picture, in pixels. Open / closed is readable at 32x32; we keep
    /// 64x64 so training can shift and zoom the pictures a little (augmentation) and still
    /// have real pixels to show the model.
    public static let outputSize = 64

    // Core Image runs these operations on the GPU. A context is expensive to create and
    // cheap to reuse, so there is ONE for the whole life of the cropper.
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Recycles the 64x64 output buffers: asking the system for new memory 60 times a
    /// second would be wasteful, a pool hands back buffers that are no longer in use.
    private let pool: CVPixelBufferPool?

    public init() {
        context = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])

        let size = Self.outputSize
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size,
            kCVPixelBufferHeightKey: size,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
        pool = created
    }

    /// The eye picture as a pixel buffer: the form the model takes directly.
    ///
    /// `rect` is in pixels, origin top-left (as `EyeLocator` gives it). Returns nil when the
    /// square is not entirely inside the frame: a half-cut eye would show the model
    /// something that never happens in a good frame.
    ///
    /// PERFORMANCE NOTE (measured 2026-11-20). The first version handed the model a CGImage
    /// through `MLFeatureValue(cgImage:)`. Core ML then built a brand-new Core Image context
    /// for every picture: 9.1 ms each, 87% of the app's processor time, and 50 MB of memory
    /// leaked per minute. A pixel buffer in the model's own format (64x64, BGRA) is used as
    /// it is: 0.12 ms.
    public func cropBuffer(_ pixelBuffer: CVPixelBuffer, rect: CGRect) -> CVPixelBuffer? {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard rect.width >= 8, CGRect(x: 0, y: 0, width: width, height: height).contains(rect),
              let pool else { return nil }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output else { return nil }

        // Core Image measures y from the BOTTOM of the picture, we measure from the top.
        let bottomUp = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        let scale = CGFloat(Self.outputSize) / rect.width

        // Move the square to the origin, then scale it to 64x64. Nothing is computed yet:
        // a CIImage is a recipe. `render` runs it, and only for the 64x64 region we ask
        // for - the rest of the frame is never touched.
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(translationX: -bottomUp.minX, y: -bottomUp.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let size = CGFloat(Self.outputSize)
        context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: size, height: size), colorSpace: colorSpace)
        return output
    }

    /// The eye picture as an image, for saving to disk or showing in a window.
    /// It is the very same pixels the model receives.
    public func crop(_ pixelBuffer: CVPixelBuffer, rect: CGRect) -> CGImage? {
        cropBuffer(pixelBuffer, rect: rect).flatMap(Self.image(from:))
    }

    /// Copies a BGRA pixel buffer into an image.
    public static func image(from buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        // "Little-endian 32-bit, alpha first" is how Core Graphics spells the byte order
        // blue, green, red, alpha.
        let layout = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layout)
        return context?.makeImage()     // makeImage copies the pixels: the buffer can be reused
    }

    /// Draws an image into a new BGRA pixel buffer of the same size, pixel for pixel
    /// (no colour conversion, no smoothing). Used for pictures read back from disk.
    public static func buffer(from image: CGImage) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &created)
        guard let buffer = created else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let layout = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // Drawing in the image's OWN colour space means "copy the numbers as they are".
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: space, bitmapInfo: layout) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
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

    /// The first version's way of making the eye picture (`createCGImage`). Kept only so
    /// a test can prove the pixel-buffer path produces the same pixels: the model was
    /// trained on pictures made this way.
    public func legacyCrop(_ pixelBuffer: CVPixelBuffer, rect: CGRect) -> CGImage? {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard rect.width >= 8, CGRect(x: 0, y: 0, width: width, height: height).contains(rect) else { return nil }
        let bottomUp = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        let scale = CGFloat(Self.outputSize) / rect.width
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(translationX: -bottomUp.minX, y: -bottomUp.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let size = CGFloat(Self.outputSize)
        return context.createCGImage(image, from: CGRect(x: 0, y: 0, width: size, height: size),
                                     format: .RGBA8, colorSpace: colorSpace)
    }
}
