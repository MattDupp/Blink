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
/// trainer's own. A frame has two eyes and about 12 ms of other work.
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
    private func answer() -> Float {
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

        var input = gray
        for stage in 0..<EyeNetWeights.stages {
            let side = Self.side >> stage, area = side * side
            let inputs = EyeNetWeights.channels[stage], outputs = EyeNetWeights.channels[stage + 1]
            // Lay every 3x3 neighbourhood out as a column, so that the convolution is ONE
            // matrix product: (outputs x inputs*9) times (inputs*9 x positions).
            input.withUnsafeBufferPointer { source in
                columns[stage].withUnsafeMutableBufferPointer { column in
                    for i in 0..<inputs { for ky in 0..<3 { for kx in 0..<3 {
                        let row = column.baseAddress! + ((i * 3 + ky) * 3 + kx) * area
                        for y in 0..<side {
                            let sy = y + ky - 1
                            if sy < 0 || sy >= side {
                                for x in 0..<side { row[y * side + x] = 0 }     // beyond the edge: zero
                                continue
                            }
                            for x in 0..<side {
                                let sx = x + kx - 1
                                row[y * side + x] = (sx < 0 || sx >= side) ? 0 : source[i * area + sy * side + sx]
                            }
                        }
                    } } }
                }
            }
            vDSP_mmul(weights.kernels[stage], 1, columns[stage], 1, &detected[stage], 1,
                      vDSP_Length(outputs), vDSP_Length(area), vDSP_Length(inputs * 9))
            // The bias, "negative means zero" (ReLU), and the strongest of every 2x2 square.
            let half = side / 2
            detected[stage].withUnsafeBufferPointer { map in
                pooled[stage].withUnsafeMutableBufferPointer { out in
                    for o in 0..<outputs {
                        let bias = weights.biases[stage][o]
                        for y in 0..<half { for x in 0..<half {
                            let p = o * area + 2 * y * side + 2 * x
                            let strongest = max(max(map[p], map[p + 1]), max(map[p + side], map[p + side + 1]))
                            out[o * half * half + y * half + x] = max(strongest + bias, 0)
                        } }
                    }
                }
            }
            input = pooled[stage]
        }
        // Average each of the 64 maps over its 4x4 positions, then one weighted sum.
        var score = weights.bias
        input.withUnsafeBufferPointer { maps in
            for o in 0..<EyeNetWeights.channels[EyeNetWeights.stages] {
                var average: Float = 0
                vDSP_meanv(maps.baseAddress! + o * 16, 1, &average, 16)
                score += average * weights.linear[o]
            }
        }
        return 1 / (1 + expf(-score))
    }
}
