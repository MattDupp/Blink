import Accelerate
import CoreImage
import CoreVideo

// The eye pictures, cut on the processor.
//
// WHY. Until 2026-11-23 every eye picture was cut by Core Image (`EyeCropper.cutWithCoreImage`).
// Core Image is built for large pictures on the graphics processor: for a picture of 64x64
// it spends its time preparing the work, not doing it. MEASURED that day on three captures
// replayed from their whole frames (`BlinkReplay --cost=crop --flat-out`): the two pictures
// of a frame cost 4.2 million instructions, a fifth of everything the app does for a frame.
// The arithmetic itself is a few thousand multiplications, and is written out here.
//
// THE PICTURES MUST STAY THE SAME: the model learned from pictures Core Image made. So this
// is not "a" resize, it is Core Image's own, step by step, as it was measured on real frames:
//
//   1. A square of up to 147 pixels is shrunk in one go: each of the 64x64 points is a
//      blend of the four camera pixels around it (bilinear).
//   2. A larger square (a face nearer than about 40 cm) is first halved, by averaging the
//      camera's pixels two by two. The pairs are the picture's own (pixels 0 and 1, 2
//      and 3, ...), not the square's. Core Image halves once for each factor of two the
//      scale is under 0.435; a square halved twice (295 pixels and more: a face nearer
//      than about 20 cm) is left to Core Image, where it costs what it always did.
//   3. The camera labels its pictures with one brightness curve (ITU-R 709) and the eye
//      pictures use another (sRGB). Core Image converts: after the blend in case 1, after
//      the halving in case 2. Here the conversion is not a formula: it is what Core Image
//      itself answers for each of the 256 levels, asked once (`ColourCurve`).
//
// MEASURED against Core Image (2026-11-23, `BlinkReplay --crops`). The 6,755 eye pictures
// of the three captures, cut both ways: 97.3% of the values are the same number, the
// others are one level of 255 apart, none is two apart. Squares of every size out of one
// stored frame: 96.2% the same up to 147 pixels, 94.5% from 148 to 294, the others one
// level apart. The model, asked about both pictures of each eye: its answers are 0.015%
// apart on average and 1.5% at most.

/// What Core Image does to the brightness of a camera picture: for each level 0...255 of
/// a channel, the level it becomes in the eye picture.
struct ColourCurve {

    /// One table per channel in the order of memory (blue, green, red): 257 numbers, the
    /// answer for each level (in levels, not rounded), and the last one again so that
    /// "level 255 and a bit" can be looked up.
    let tables: [[Float]]
    /// The same curve for the average of four levels, looked up by their SUM (0...1020):
    /// a quarter, a half or three quarters of the way between two levels.
    let quarters: [[Float]]

    init(tables: [[Float]]) {
        self.tables = tables
        quarters = tables.map { table in
            (0...(255 * 4)).map { sum in
                let level = sum / 4, share = Float(sum % 4) / 4
                return table[level] * (1 - share) + table[level + 1] * share
            }
        }
    }

    /// The labels a camera picture carries about its colours. Two pictures with the same
    /// labels are converted the same way.
    struct Labels {
        static let keys: [CFString] = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                                       kCVImageBufferGammaLevelKey, kCVImageBufferCGColorSpaceKey,
                                       kCVImageBufferICCProfileKey]
        let values: [CFTypeRef?]

        init(of buffer: CVPixelBuffer) {
            values = Self.keys.map { CVBufferCopyAttachment(buffer, $0, nil) }
        }

        func same(as other: Labels) -> Bool {
            zip(values, other.values).allSatisfy { mine, theirs in
                switch (mine, theirs) {
                case (nil, nil): return true
                case (let mine?, let theirs?): return CFEqual(mine, theirs)
                default: return false
                }
            }
        }
    }

    /// Asks Core Image: a picture holding every level, labelled like `source`, goes
    /// through `context` exactly as an eye picture does, and what comes out is the curve.
    ///
    /// Nil when the conversion is not one curve per channel (a camera whose colours are
    /// not the screen's: red would then leak into green). Such pictures stay with Core Image.
    static func measure(like source: CVPixelBuffer, context: CIContext, colorSpace: CGColorSpace) -> ColourCurve? {
        let levels = 256
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, levels, 4, kCVPixelFormatType_32BGRA, attributes, &made)
        guard let picture = made else { return nil }
        if let labels = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(picture, labels, .shouldPropagate)
        }

        // Four lines: every grey, then every level of blue alone, of green, of red.
        CVPixelBufferLockBaseAddress(picture, [])
        guard let base = CVPixelBufferGetBaseAddress(picture)?.assumingMemoryBound(to: UInt8.self) else {
            CVPixelBufferUnlockBaseAddress(picture, [])
            return nil
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(picture)
        for line in 0..<4 {
            for level in 0..<levels {
                let pixel = base + line * rowBytes + level * 4
                for channel in 0..<3 { pixel[channel] = (line == 0 || line == channel + 1) ? UInt8(level) : 0 }
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(picture, [])

        // The answers as unrounded numbers, 0...1, in the order red, green, blue, alpha.
        var answers = [Float](repeating: 0, count: levels * 4 * 4)
        context.render(CIImage(cvPixelBuffer: picture), toBitmap: &answers, rowBytes: levels * 4 * MemoryLayout<Float>.stride,
                       bounds: CGRect(x: 0, y: 0, width: levels, height: 4), format: .RGBAf, colorSpace: colorSpace)
        /// The answer on `line` for `level`, channel in the order of memory (blue first).
        func answer(_ line: Int, _ level: Int, _ channel: Int) -> Float {
            answers[(line * levels + level) * 4 + (2 - channel)]
        }

        var tables: [[Float]] = []
        for channel in 0..<3 {
            var table: [Float] = []
            for level in 0..<levels {
                let grey = answer(0, level, channel), alone = answer(channel + 1, level, channel)
                // One curve per channel means: a channel answers the same alone and in a
                // grey, and leaves the two others at zero.
                guard grey.isFinite, abs(grey - alone) < 0.002 else { return nil }
                for other in 0..<3 where other != channel {
                    guard abs(answer(channel + 1, level, other)) < 0.002 else { return nil }
                }
                table.append(min(max(grey, 0), 1) * 255)
            }
            table.append(table[levels - 1])
            tables.append(table)
        }
        return ColourCurve(tables: tables)
    }
}

/// A block of numbers that stays where it is in memory, so that Accelerate's routines can
/// be handed its address. It only ever grows.
private final class Numbers {
    private var memory: UnsafeMutableBufferPointer<Float>

    init(_ count: Int = 0) {
        memory = .allocate(capacity: max(count, 1))
        memory.initialize(repeating: 0)
    }

    deinit { memory.deallocate() }

    /// The address of the first number.
    var start: UnsafeMutablePointer<Float> { memory.baseAddress! }

    /// Makes room for `count` numbers. What was there is not kept.
    func hold(_ count: Int) {
        guard memory.count < count else { return }
        memory.deallocate()
        memory = .allocate(capacity: count)
        memory.initialize(repeating: 0)
    }
}

/// Cuts a square of a camera picture into a 64x64 eye picture, the way Core Image does.
/// One instance belongs to one thread: it keeps its working memory between calls.
final class DirectCrop {

    static let side = EyeCropper.outputSize

    /// Under this scale Core Image halves the picture before it blends, once for each
    /// factor of two. MEASURED 2026-11-23: a square of 147 pixels (scale 0.4354) is not
    /// halved, one of 148 (0.4324) is; 294 and 295, 588 and 589 behave the same way.
    static let halveUnder: Float = 0.435

    /// How many times a square of `width` pixels is halved before the blend.
    static func halvings(forSquare width: CGFloat) -> Int {
        var scale = Float(side) / Float(width), count = 0
        while scale < halveUnder {
            scale *= 2
            count += 1
        }
        return count
    }

    /// vImage shares a large conversion out among several threads unless told not to.
    /// For these small pictures the threads cost more than the conversion: they spin
    /// while they wait for their share (SEEN 2026-11-23 in a profile of the replay: a
    /// third of all the samples were threads waiting for a turn).
    private static let oneThread = vImage_Flags(kvImageDoNotTile)

    // Working memory, kept between calls.
    /// The picture around the square, as numbers: one plane per byte of a pixel (blue,
    /// green, red, and how opaque). The camera's own levels in case 1, the halved
    /// picture in case 2 (which has no use for the fourth).
    private let levels = [Numbers(), Numbers(), Numbers(), Numbers()]
    private let lineA = Numbers(), lineB = Numbers(), sums = Numbers()
    /// The 64x64 picture being made: one plane per colour, and the one being blended.
    private let planes = [Numbers(side * side), Numbers(side * side), Numbers(side * side)]
    private let blended = Numbers(side * side)
    private let columns = Numbers(side)

    /// Fills `output` (64x64, BGRA) with the square `rect` of `source` (BGRA), `rect` in
    /// pixels from the top-left. False when this picture is not one it can cut exactly
    /// as Core Image would: nothing is written then, and the caller asks Core Image.
    func cut(_ source: CVPixelBuffer, rect: CGRect, curve: ColourCurve, into output: CVPixelBuffer) -> Bool {
        let side = Self.side
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              abs(rect.width - rect.height) < 0.01, rect.width >= 8 else { return false }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        // A square halved twice or more is left to Core Image (see the top of this file).
        let halvings = Self.halvings(forSquare: rect.width)
        guard halvings <= 1 else { return false }
        let factor = 1 << halvings
        // The pairs of a halving are counted from the picture's own corner. When the
        // picture does not divide evenly, its last pair is half a pair: left to Core Image.
        guard width % factor == 0, height % factor == 0 else { return false }

        // Where each of the 64 points falls, measured in pixels of the (halved) picture,
        // from the middle of its first pixel.
        let step = Float(rect.width) / Float(side) / Float(factor)
        let firstX = Float(rect.minX) / Float(factor) + 0.5 * step - 0.5
        let firstY = Float(rect.minY) / Float(factor) + 0.5 * step - 0.5
        let lastX = firstX + Float(side - 1) * step, lastY = firstY + Float(side - 1) * step
        // The pixels that are blended: from `left` to `right`, from `upper` to `lower`.
        let left = Int(firstX.rounded(.down)), right = Int(lastX.rounded(.down)) + 1
        let upper = Int(firstY.rounded(.down)), lower = Int(lastY.rounded(.down)) + 1
        // A point whose four pixels are not all in the picture (an enlarged eye at the
        // very edge of the frame) is left to Core Image too.
        guard firstX >= 0, firstY >= 0, right < width / factor, lower < height / factor else { return false }
        let across = right - left + 1, down = lower - upper + 1

        guard CVPixelBufferGetWidth(output) == side, CVPixelBufferGetHeight(output) == side,
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA else { return false }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(source) else { return false }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let cut = CVPixelBufferGetBaseAddress(output) else { return false }
        let rowBytes = CVPixelBufferGetBytesPerRow(source)
        let full: [Float] = [255, 255, 255, 255], none: [Float] = [0, 0, 0, 0]

        // The picture around the square, as numbers.
        for plane in levels { plane.hold(across * down) }
        if halvings == 0 {
            // Case 1: the camera's own levels. The four bytes of every pixel go to four
            // planes in one pass.
            var region = vImage_Buffer(data: pixels + upper * rowBytes + left * 4,
                                       height: vImagePixelCount(down), width: vImagePixelCount(across), rowBytes: rowBytes)
            var planar = levels.map { Self.buffer($0, width: across, height: down) }
            guard vImageConvert_ARGB8888toPlanarF(&region, &planar[0], &planar[1], &planar[2], &planar[3],
                                                  full, none, Self.oneThread) == kvImageNoError else { return false }
        } else {
            halve(pixels.assumingMemoryBound(to: UInt8.self), rowBytes: rowBytes, left: left, upper: upper,
                  across: across, down: down, curve: curve)
        }

        // The same 64 places across for every line: the pixel's number and how far past it.
        for x in 0..<side { columns.start[x] = firstX + Float(x) * step - Float(left) }
        lineA.hold(across)
        let count = vDSP_Length(side * side)

        for channel in 0..<3 {
            // The blend: each point from the two lines around it, then from the two
            // pixels beside it on the line that makes.
            let level = levels[channel].start
            for y in 0..<side {
                let place = firstY + Float(y) * step - Float(upper)
                let above = Int(place.rounded(.down))
                var share = place - Float(above)
                vDSP_vintb(level + above * across, 1, level + (above + 1) * across, 1, &share, lineA.start, 1, vDSP_Length(across))
                vDSP_vlint(lineA.start, columns.start, 1, blended.start + y * side, 1, vDSP_Length(side), vDSP_Length(across))
            }
            // Case 1 converts the brightness now; case 2 did it after the halving.
            if halvings == 0 {
                vDSP_vlint(curve.tables[channel], blended.start, 1, planes[channel].start, 1, count, vDSP_Length(curve.tables[channel].count))
            } else {
                planes[channel].start.update(from: blended.start, count: side * side)
            }
        }

        // The three planes back into pixels of four bytes, rounded to whole levels; the
        // fourth byte says how opaque a pixel is: entirely.
        var picture = vImage_Buffer(data: cut, height: vImagePixelCount(side), width: vImagePixelCount(side),
                                    rowBytes: CVPixelBufferGetBytesPerRow(output))
        var planar = planes.map { Self.buffer($0, width: side, height: side) }
        return vImageConvert_PlanarFToBGRX8888(&planar[0], &planar[1], &planar[2], 255, &picture, full, none, Self.oneThread) == kvImageNoError
    }

    /// A plane of numbers as vImage wants it described: where it is, how many across and down.
    private static func buffer(_ numbers: Numbers, width: Int, height: Int) -> vImage_Buffer {
        vImage_Buffer(data: numbers.start, height: vImagePixelCount(height), width: vImagePixelCount(width),
                      rowBytes: width * MemoryLayout<Float>.stride)
    }

    /// Case 2: the picture halved around the square, into `levels` (`across` x `down`, one
    /// plane per colour): the camera's levels averaged two by two, then the brightness converted.
    private func halve(_ pixels: UnsafePointer<UInt8>, rowBytes: Int, left: Int, upper: Int, across: Int, down: Int,
                       curve: ColourCurve) {
        // A line of the camera's picture under a line of the result: two pixels of four
        // bytes for each of its points.
        let bytes = across * 8
        lineA.hold(bytes)
        lineB.hold(bytes)
        sums.hold(across)

        for y in 0..<down {
            // Two lines of the camera's picture, every byte as a number, added.
            let above = pixels + (upper + y) * 2 * rowBytes + left * 8
            vDSP_vfltu8(above, 1, lineA.start, 1, vDSP_Length(bytes))
            vDSP_vfltu8(above + rowBytes, 1, lineB.start, 1, vDSP_Length(bytes))
            vDSP_vadd(lineA.start, 1, lineB.start, 1, lineA.start, 1, vDSP_Length(bytes))
            for channel in 0..<3 {
                // Then each pixel with its right-hand neighbour: the same colour is 4
                // numbers further, and the next pair 8. That is the sum of four levels,
                // which the curve's second table is looked up by.
                vDSP_vadd(lineA.start + channel, 8, lineA.start + channel + 4, 8, sums.start, 1, vDSP_Length(across))
                vDSP_vindex(curve.quarters[channel], sums.start, 1, levels[channel].start + y * across, 1, vDSP_Length(across))
            }
        }
    }
}
