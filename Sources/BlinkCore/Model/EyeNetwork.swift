import Accelerate
import CoreVideo
import Foundation

/// The numbers of a trained EyeNet, in the form a model that only ANSWERS needs.
///
/// While it learns, each of the network's four stages has a convolution and a batch
/// normalisation. Once training is over the normalisation is a fixed scale and shift, so it
/// is "folded" into the convolution: one set of weights and one bias per stage, 60,289
/// numbers in all. Both trainers write this form: the one inside the app (`EyeTrainer`) and
/// the Python one (`training/convert.py`, which writes models/eyenet.weights).
public struct EyeNetWeights: Equatable {

    /// How many maps each stage reads and produces: 1 grey picture in, then 16, 32, 64, 64.
    public static let channels = [1, 16, 32, 64, 64]
    public static let stages = 4

    /// Per stage, `outputs` rows of `inputs * 9` numbers: one 3x3 detector per input map.
    public var kernels: [[Float]]
    /// Per stage, one number per output map.
    public var biases: [[Float]]
    /// The final weighted sum over the 64 numbers that describe the eye.
    public var linear: [Float]
    public var bias: Float

    public enum WeightsError: Error, CustomStringConvertible {
        case notAWeightsFile(String)

        public var description: String {
            switch self {
            case .notAWeightsFile(let what): return "This is not an eye model: \(what)."
            }
        }
    }

    /// How many numbers each part holds, in the order of the file.
    static var sizes: [Int] {
        var sizes: [Int] = []
        for stage in 0..<stages {
            sizes += [channels[stage + 1] * channels[stage] * 9, channels[stage + 1]]
        }
        return sizes + [channels[stages], 1]
    }

    /// Every number, one after the other: the stages' weights and biases, then the sum's.
    public var flat: [Float] {
        var all: [Float] = []
        for stage in 0..<Self.stages { all += kernels[stage] + biases[stage] }
        return all + linear + [bias]
    }

    public init(flat: [Float]) throws {
        let sizes = Self.sizes
        guard flat.count == sizes.reduce(0, +) else {
            throw WeightsError.notAWeightsFile("it holds \(flat.count) numbers, not \(sizes.reduce(0, +))")
        }
        guard flat.allSatisfy(\.isFinite) else {
            throw WeightsError.notAWeightsFile("some of its numbers are not finite")
        }
        var parts: [[Float]] = [], start = 0
        for size in sizes {
            parts.append(Array(flat[start..<start + size]))
            start += size
        }
        kernels = (0..<Self.stages).map { parts[2 * $0] }
        biases = (0..<Self.stages).map { parts[2 * $0 + 1] }
        linear = parts[2 * Self.stages]
        bias = parts[2 * Self.stages + 1][0]
    }

    // MARK: The file

    /// The file starts with these eight bytes, then holds the numbers as 32-bit floats
    /// (little-endian, the Mac's own order): 241 KB.
    static let signature = Data("EYENET01".utf8)

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.prefix(Self.signature.count) == Self.signature else {
            throw WeightsError.notAWeightsFile("the file does not start with EYENET01")
        }
        let body = data.dropFirst(Self.signature.count)
        guard body.count % MemoryLayout<Float>.stride == 0 else {
            throw WeightsError.notAWeightsFile("the file is cut short")
        }
        var values = [Float](repeating: 0, count: body.count / MemoryLayout<Float>.stride)
        _ = values.withUnsafeMutableBytes { body.copyBytes(to: $0) }
        try self.init(flat: values)
    }

    public func write(to url: URL) throws {
        var data = Self.signature
        flat.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url, options: .atomic)
    }
}

/// EyeNet answering, written out in Swift: a 64x64 eye picture in, "probability closed" out.
///
/// WHY NOT CORE ML, as for the model trained in Python? Core ML has no public way to put
/// new weights into a model (measured 2026-11-20: `MLParameterKey.weights` can only be read
/// inside an update task), and its own on-device training cannot train this network's
/// batch normalisation. The network is small enough to write out: four convolutions, each
/// one matrix product done by Accelerate, the Mac's own linear-algebra library.
///
/// MEASURED (2026-11-20, 908 real pictures, one at a time on the processor): 0.24 ms a
/// picture, against 0.10 ms for the Core ML model; the answers are within 0.000001 of the
/// trainer's own. A frame has two eyes and about 12 ms of other work. Since 2026-11-23 it
/// is 0.13 ms a picture: see `answer`.
///
/// One instance belongs to one thread: it keeps its working memory between calls.
public final class EyeNetwork: EyeJudging {

    public static let side = 64
    public static let pixels = side * side

    private let weights: EyeNetWeights
    // Working memory, allocated once.
    private var gray = [Float](repeating: 0, count: EyeNetwork.pixels)
    private var columns: [[Float]] = []
    private var detected: [[Float]] = []
    private var pooled: [[Float]] = []
    /// Each pixel paired with its right-hand neighbour: half of the largest stage's maps.
    private var pairs = [Float](repeating: 0, count: EyeNetWeights.channels[1] * EyeNetwork.pixels / 2)

    public init(weights: EyeNetWeights) {
        self.weights = weights
        for stage in 0..<EyeNetWeights.stages {
            let side = Self.side >> stage, area = side * side
            columns.append([Float](repeating: 0, count: EyeNetWeights.channels[stage] * 9 * area))
            detected.append([Float](repeating: 0, count: EyeNetWeights.channels[stage + 1] * area))
            pooled.append([Float](repeating: 0, count: EyeNetWeights.channels[stage + 1] * area / 4))
        }
    }

    /// The probability that the eye in this picture is closed: 0 = open, 1 = closed.
    /// The buffer must be what `EyeCropper.cropBuffer` produces: 64x64, BGRA.
    public func closedProbability(of eye: CVPixelBuffer) throws -> Double {
        guard CVPixelBufferGetWidth(eye) == Self.side, CVPixelBufferGetHeight(eye) == Self.side,
              CVPixelBufferGetPixelFormatType(eye) == kCVPixelFormatType_32BGRA else {
            throw EyeClassifier.ClassifierError.wrongPicture("expected \(Self.side) x \(Self.side) BGRA, got "
                + "\(CVPixelBufferGetWidth(eye)) x \(CVPixelBufferGetHeight(eye))")
        }
        CVPixelBufferLockBaseAddress(eye, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(eye, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(eye)?.assumingMemoryBound(to: UInt8.self) else {
            throw EyeClassifier.ClassifierError.wrongPicture("its pixels cannot be read")
        }
        Self.gray(fromBGRA: base, bytesPerRow: CVPixelBufferGetBytesPerRow(eye), into: &gray)
        return Double(answer())
    }

    /// The same, for a picture already turned into 4,096 brightness values (0...1).
    public func closedProbability(ofGray picture: UnsafePointer<Float>) -> Double {
        gray.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: picture, count: Self.pixels) }
        return Double(answer())
    }

    /// Brightness only: the weighted mix of red, green and blue that training/model.py
    /// uses. Memory holds each pixel as blue, green, red, alpha.
    public static func gray(fromBGRA base: UnsafePointer<UInt8>, bytesPerRow: Int, into gray: inout [Float]) {
        for y in 0..<side {
            let row = base + y * bytesPerRow
            for x in 0..<side {
                let p = row + x * 4
                gray[y * side + x] = (0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])) / 255
            }
        }
    }

    /// Runs the network on `gray`.
    ///
    /// WHERE ITS TIME WENT (MEASURED 2026-11-23, on battery). The first version filled
    /// the columns and took the strongest of each square one number at a time, in Swift
    /// loops. Replayed at the camera's pace (`BlinkReplay --cost`, 121 s of recorded
    /// frames), the model was then 335 million instructions a second: as much work as
    /// finding the eyes with Vision, and four times what Core ML needs for the same
    /// network (84). Most of it was those loops, not the matrix products. They now move
    /// whole rows and whole maps with the Mac's own routines:
    ///
    ///   - one picture: 2.10 million instructions instead of 5.35, and 0.13 ms instead of
    ///     0.25 flat out (1,500 pictures, the two versions side by side);
    ///   - the whole pipeline in the replay: 630 to 637 million instructions a second
    ///     instead of 838, and the model stage 0.60 to 0.68 ms a frame instead of 1.2 to 1.3.
    ///
    /// THE ANSWERS ARE THE SAME, TO THE LAST BIT: every product and every sum is the one
    /// it was, in the order it was. On those 1,500 pictures, with a trained model's
    /// weights and with made-up ones, not one answer of the two versions differed, and
    /// the replay counts the same 77 blinks. What is left is the matrix product itself
    /// (`cblas_sgemm` gives the same count as `vDSP_mmul`).
    private func answer() -> Float {
        1 / (1 + expf(-score()))
    }

    /// The network's number before it is squeezed into 0...1, for a picture given as
    /// brightness values: what the tests compare, since two different numbers can both
    /// be squeezed to 1.
    func score(ofGray picture: UnsafePointer<Float>) -> Float {
        gray.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: picture, count: Self.pixels) }
        return score()
    }

    private func score() -> Float {
        let count = vDSP_Length(Self.pixels)
        // Every picture gets the same average brightness (0) and the same contrast (1):
        // a picture taken in a dim room and the same one in daylight become identical.
        var mean: Float = 0
        vDSP_meanv(gray, 1, &mean, count)
        var negative = -mean
        vDSP_vsadd(gray, 1, &negative, &gray, 1, count)
        var power: Float = 0
        vDSP_measqv(gray, 1, &power, count)
        var scale = 1 / (power.squareRoot() + 1e-4)
        vDSP_vsmul(gray, 1, &scale, &gray, 1, count)

        for stage in 0..<EyeNetWeights.stages {
            let side = Self.side >> stage, area = side * side
            let inputs = EyeNetWeights.channels[stage], outputs = EyeNetWeights.channels[stage + 1]
            // Lay every 3x3 neighbourhood out as a column, so that the convolution is ONE
            // matrix product: (outputs x inputs*9) times (inputs*9 x positions).
            //
            // Row (i, ky, kx) of the columns is input map i moved by one pixel: up or
            // down for ky, left or right for kx, with zeros where the move leaves the
            // picture. So each line of it is a line of the map, copied in one go.
            (stage == 0 ? gray : pooled[stage - 1]).withUnsafeBufferPointer { source in
                columns[stage].withUnsafeMutableBufferPointer { column in
                    for i in 0..<inputs {
                        let map = source.baseAddress! + i * area
                        for ky in 0..<3 { for kx in 0..<3 {
                            let row = column.baseAddress! + ((i * 3 + ky) * 3 + kx) * area
                            for y in 0..<side {
                                let line = row + y * side
                                let sy = y + ky - 1
                                if sy < 0 || sy >= side {
                                    vDSP_vclr(line, 1, vDSP_Length(side))       // beyond the edge: zero
                                    continue
                                }
                                let from = map + sy * side
                                switch kx {
                                case 0:                                          // the pixel to the left
                                    line[0] = 0
                                    (line + 1).update(from: from, count: side - 1)
                                case 1:
                                    line.update(from: from, count: side)
                                default:                                         // the pixel to the right
                                    line.update(from: from + 1, count: side - 1)
                                    line[side - 1] = 0
                                }
                            }
                        } }
                    }
                }
            }
            vDSP_mmul(weights.kernels[stage], 1, columns[stage], 1, &detected[stage], 1,
                      vDSP_Length(outputs), vDSP_Length(area), vDSP_Length(inputs * 9))
            // The strongest of every 2x2 square, then the bias and "negative means zero"
            // (ReLU). The strongest of four is the stronger of two pairs: first each
            // pixel with its right-hand neighbour, over all the maps at once, then each
            // line of those with the line under it.
            let half = side / 2
            detected[stage].withUnsafeBufferPointer { map in
                pairs.withUnsafeMutableBufferPointer { pair in
                    pooled[stage].withUnsafeMutableBufferPointer { out in
                        vDSP_vmax(map.baseAddress!, 2, map.baseAddress! + 1, 2, pair.baseAddress!, 1,
                                  vDSP_Length(outputs * area / 2))
                        var zero: Float = 0
                        for o in 0..<outputs {
                            let lines = pair.baseAddress! + o * side * half
                            let strongest = out.baseAddress! + o * half * half
                            for y in 0..<half {
                                vDSP_vmax(lines + 2 * y * half, 1, lines + (2 * y + 1) * half, 1,
                                          strongest + y * half, 1, vDSP_Length(half))
                            }
                            var bias = weights.biases[stage][o]
                            vDSP_vsadd(strongest, 1, &bias, strongest, 1, vDSP_Length(half * half))
                            vDSP_vthres(strongest, 1, &zero, strongest, 1, vDSP_Length(half * half))
                        }
                    }
                }
            }
        }
        // Average each of the 64 maps over its 4x4 positions, then one weighted sum.
        var score = weights.bias
        pooled[EyeNetWeights.stages - 1].withUnsafeBufferPointer { maps in
            for o in 0..<EyeNetWeights.channels[EyeNetWeights.stages] {
                var average: Float = 0
                vDSP_meanv(maps.baseAddress! + o * 16, 1, &average, 16)
                score += average * weights.linear[o]
            }
        }
        return score
    }
}
