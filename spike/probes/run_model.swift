// PROBE: two ways for the app to RUN a model trained in the app, compared with the
// trainer's own answers on real pictures, and timed one picture at a time on the CPU.
//
//   1. "shell": a fixed Core ML model with no weights inside; the weights are inputs.
//   2. "plain": the network written out in Swift with Accelerate (no Core ML at all).
//
//   run_model <jobs.json> <results.json> <job name> <weights stem> <shell.mlmodelc> [<EyeNet.mlmodelc>]
import Accelerate
import CoreML
import CoreVideo
import Foundation
import ImageIO

struct Job: Decodable { let name: String; let predict: [Int] }
struct Jobs: Decodable { let pictures: [String]; let jobs: [Job] }
struct Answer: Decodable { let closed: [Float] }

let arguments = CommandLine.arguments
let jobs = try JSONDecoder().decode(Jobs.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let results = try JSONDecoder().decode([String: Answer].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
let job = jobs.jobs.first { $0.name == arguments[3] }!
let expected = results[arguments[3]]!.closed
let paths = job.predict.map { jobs.pictures[$0] }

// The trained numbers: one flat file of floats and a list of what is where.
let blob = try Data(contentsOf: URL(fileURLWithPath: arguments[4] + ".bin"))
let index = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[4] + ".json"))) as! [[String: Any]]
var weights: [String: (shape: [Int], values: [Float])] = [:]
for part in index {
    let offset = part["offset"] as! Int, count = part["count"] as! Int
    let values = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)[offset..<offset + count]) }
    weights[part["name"] as! String] = (part["shape"] as! [Int], values)
}

/// A PNG as a 64x64 BGRA pixel buffer, numbers copied as they are (as EyeCropper.buffer does).
func buffer(_ path: String) -> CVPixelBuffer {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var created: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &created)
    let buffer = created!
    CVPixelBufferLockBaseAddress(buffer, [])
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 64, height: 64, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

// MARK: - 2. The network in plain Swift

/// EyeNet answering, one picture at a time: 64x64 BGRA in, probability "closed" out.
final class PlainEyeNet {
    let channels = [1, 16, 32, 64, 64]
    var kernels: [[Float]] = [], biases: [[Float]] = []
    let linear: [Float], bias: Float
    // Working memory, allocated once.
    var columns: [[Float]] = [], detected: [[Float]] = [], pooled: [[Float]] = []

    init(_ weights: [String: (shape: [Int], values: [Float])]) {
        for stage in 0..<4 {
            kernels.append(weights["conv\(stage).weight"]!.values)     // (out, in * 9)
            biases.append(weights["conv\(stage).bias"]!.values)
            let side = 64 >> stage
            columns.append([Float](repeating: 0, count: channels[stage] * 9 * side * side))
            detected.append([Float](repeating: 0, count: channels[stage + 1] * side * side))
            pooled.append([Float](repeating: 0, count: channels[stage + 1] * side * side / 4))
        }
        linear = weights["linear.weight"]!.values
        bias = weights["linear.bias"]!.values[0]
    }

    func closedProbability(of buffer: CVPixelBuffer) -> Float {
        // The model's own preprocessing: grey, then the same brightness and contrast for all.
        var gray = [Float](repeating: 0, count: 4096)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<64 { for x in 0..<64 {
            let p = base + y * rowBytes + x * 4
            gray[y * 64 + x] = (0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])) / 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        var mean: Float = 0
        vDSP_meanv(gray, 1, &mean, 4096)
        var negative = -mean
        vDSP_vsadd(gray, 1, &negative, &gray, 1, 4096)
        var power: Float = 0
        vDSP_measqv(gray, 1, &power, 4096)
        var scale = 1 / (power.squareRoot() + 1e-4)
        vDSP_vsmul(gray, 1, &scale, &gray, 1, 4096)

        var input = gray
        for stage in 0..<4 {
            let side = 64 >> stage, inputs = channels[stage], outputs = channels[stage + 1], area = side * side
            // Lay every 3x3 neighbourhood out as a column, so the convolution is one
            // matrix product: (outputs x inputs*9) times (inputs*9 x positions).
            input.withUnsafeBufferPointer { source in
                columns[stage].withUnsafeMutableBufferPointer { column in
                    for i in 0..<inputs { for ky in 0..<3 { for kx in 0..<3 {
                        let row = column.baseAddress! + ((i * 3 + ky) * 3 + kx) * area
                        for y in 0..<side {
                            let sy = y + ky - 1
                            if sy < 0 || sy >= side { for x in 0..<side { row[y * side + x] = 0 }; continue }
                            for x in 0..<side {
                                let sx = x + kx - 1
                                row[y * side + x] = (sx < 0 || sx >= side) ? 0 : source[i * area + sy * side + sx]
                            }
                        }
                    } } }
                }
            }
            vDSP_mmul(kernels[stage], 1, columns[stage], 1, &detected[stage], 1, vDSP_Length(outputs), vDSP_Length(area), vDSP_Length(inputs * 9))
            // Bias, ReLU, and the strongest of every 2x2 square.
            let half = side / 2
            detected[stage].withUnsafeBufferPointer { map in
                pooled[stage].withUnsafeMutableBufferPointer { out in
                    for o in 0..<outputs {
                        let b = biases[stage][o]
                        for y in 0..<half { for x in 0..<half {
                            let p = o * area + 2 * y * side + 2 * x
                            let strongest = max(max(map[p], map[p + 1]), max(map[p + side], map[p + side + 1]))
                            out[o * half * half + y * half + x] = max(strongest + b, 0)
                        } }
                    }
                }
            }
            input = pooled[stage]
        }
        // Average each of the 64 maps over its 4x4 positions, then one weighted sum.
        var score = bias
        for o in 0..<64 {
            var average: Float = 0
            input.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + o * 16, 1, &average, 16) }
            score += average * linear[o]
        }
        return 1 / (1 + expf(-score))
    }
}

// MARK: - The comparison

let buffers = paths.map(buffer)
func report(_ name: String, _ answers: [Float], seconds: Double) {
    var worst: Float = 0, disagree = 0
    for (a, e) in zip(answers, expected) { worst = max(worst, abs(a - e)); if (a > 0.5) != (e > 0.5) { disagree += 1 } }
    print(String(format: "%@ on %d pictures: largest difference with the trainer %.6f, %d disagreements on open/closed, %.3f ms per picture",
                 name.padding(toLength: 22, withPad: " ", startingAt: 0), answers.count, worst, disagree, seconds / Double(answers.count) * 1000))
}
func timed(_ body: () throws -> [Float]) rethrows -> ([Float], Double) {
    _ = try body()                      // once to warm up
    let start = Date()
    let answers = try body()
    return (answers, Date().timeIntervalSince(start))
}

let plain = PlainEyeNet(weights)
let (plainAnswers, plainSeconds) = timed { buffers.map { plain.closedProbability(of: $0) } }
report("plain Swift", plainAnswers, seconds: plainSeconds)

let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuOnly
do {
    let shell = try MLModel(contentsOf: URL(fileURLWithPath: arguments[5]), configuration: configuration)
    var fixed: [String: Any] = [:]
    for (stage, (w, b)) in [("0", ("w0", "b0")), ("1", ("w1", "b1")), ("2", ("w2", "b2")), ("3", ("w3", "b3"))] {
        for (input, part) in [(w, "conv\(stage).weight"), (b, "conv\(stage).bias")] {
            let array = try MLMultiArray(shape: weights[part]!.shape as [NSNumber], dataType: .float32)
            weights[part]!.values.withUnsafeBufferPointer { source in
                array.withUnsafeMutableBytes { target, _ in target.bindMemory(to: Float.self).baseAddress!.update(from: source.baseAddress!, count: source.count) }
            }
            fixed[input] = array
        }
    }
    for (input, part) in [("wl", "linear.weight"), ("bl", "linear.bias")] {
        let array = try MLMultiArray(shape: weights[part]!.shape as [NSNumber], dataType: .float32)
        for (i, value) in weights[part]!.values.enumerated() { array[i] = NSNumber(value: value) }
        fixed[input] = array
    }
    let (shellAnswers, shellSeconds) = try timed {
        try buffers.map { buffer in
            var inputs = fixed
            inputs["eye"] = MLFeatureValue(pixelBuffer: buffer)
            let output = try shell.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
            return output.featureValue(for: "closed")!.multiArrayValue![0].floatValue
        }
    }
    report("Core ML, weights fed", shellAnswers, seconds: shellSeconds)
} catch { print("Core ML shell failed: \(error)") }

if arguments.count > 6 {
    // The yardstick: today's model (trained in Python, weights inside), on the same pictures.
    let today = try MLModel(contentsOf: URL(fileURLWithPath: arguments[6]), configuration: configuration)
    let (_, seconds) = try timed {
        try buffers.map { buffer in
            let output = try today.prediction(from: MLDictionaryFeatureProvider(dictionary: ["eye": MLFeatureValue(pixelBuffer: buffer)]))
            return output.featureValue(for: "closed")!.multiArrayValue![0].floatValue
        }
    }
    print(String(format: "today's Core ML model (other weights): %.3f ms per picture", seconds / Double(buffers.count) * 1000))
}
