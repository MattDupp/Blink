import Foundation
import Metal
import MetalPerformanceShadersGraph

/// EyeNet (training/model.py) written with MPSGraph, Apple's framework for running and
/// DIFFERENTIATING a network on the Mac's GPU. PyTorch's own "mps" device is built on the
/// same framework, so this is the Python route's engine without Python.
///
/// Same network: four stages of (3x3 convolution, batch normalisation, ReLU, 2x2 max
/// pool), an average over the picture, dropout, one weighted sum. Same training: AdamW,
/// one-cycle learning rate, binary cross-entropy, 128 pictures a step.
final class EyeNetGraph {

    static let channels = [1, 16, 32, 64, 64]
    static let batchSize = 128
    static let answerBatch = 512
    /// Every step holds exactly 128 pictures (the last one of an epoch is topped up).
    /// Tried for speed (2026-11-20): no gain, 18.7 s either way, and on three seeds it
    /// counted 214 of 216 blinks with 3 false where the open shape counted 216 with 1.
    /// Off: the last step of an epoch is smaller, as in PyTorch.
    static var fixedShapes = false

    private let graph = MPSGraph()
    private let device: MPSGraphDevice
    private let queue: MTLCommandQueue

    // What is fed at every step.
    private let pictures: MPSGraphTensor      // (N, 64, 64, 1) grey, 0..1
    private let asked: MPSGraphTensor         // the same, for answering
    private let labels: MPSGraphTensor        // (N, 1): 1 = closed
    private let dropoutMask: MPSGraphTensor   // (N, 64): 0, or 1 / 0.8
    private let decay, stepSize, beta1, oneMinusBeta1, secondCorrection: MPSGraphTensor

    // The network's numbers.
    private var convolutions: [MPSGraphTensor] = []
    private var gammas: [MPSGraphTensor] = [], betas: [MPSGraphTensor] = []
    private var runningMeans: [MPSGraphTensor] = [], runningVariances: [MPSGraphTensor] = []
    private var linear: MPSGraphTensor!, bias: MPSGraphTensor!

    private var loss: MPSGraphTensor!
    private var updates: [MPSGraphOperation] = []
    private var closed: MPSGraphTensor!       // the answer in use: probability closed
    private var gradientTensors: [MPSGraphTensor] = []

    /// MPSGraph's default ("level 1") may place parts of a graph on the processor or the
    /// Neural Engine instead of the GPU. With variables in the graph that ended one run of
    /// the spike with "multi-device variable handling not correctly implemented" (an
    /// assertion inside the framework, 2026-11-20). Level 0 keeps everything on the GPU.
    static var everythingOnTheGPU = true
    /// Seconds spent altering pictures, and running the graph, in the last training.
    private(set) var secondsAltering = 0.0, secondsOnGPU = 0.0

    private func run(_ feeds: [MPSGraphTensor: MPSGraphTensorData], _ targets: [MPSGraphTensor],
                     _ operations: [MPSGraphOperation]? = nil) -> [MPSGraphTensor: MPSGraphTensorData] {
        guard Self.everythingOnTheGPU else {
            return graph.run(with: queue, feeds: feeds, targetTensors: targets, targetOperations: operations)
        }
        let compilation = MPSGraphCompilationDescriptor()
        compilation.optimizationLevel = .level0
        let execution = MPSGraphExecutionDescriptor()
        execution.compilationDescriptor = compilation
        execution.waitUntilCompleted = true
        return graph.runAsync(with: queue, feeds: feeds, targetTensors: targets, targetOperations: operations, executionDescriptor: execution)
    }

    init?(seed: UInt64) {
        guard let metal = MTLCreateSystemDefaultDevice(), let queue = metal.makeCommandQueue() else { return nil }
        device = MPSGraphDevice(mtlDevice: metal)
        self.queue = queue
        var random = Random(seed: seed &* 7_919 &+ 13)

        let batch = Self.fixedShapes ? Self.batchSize : -1, many = Self.fixedShapes ? Self.answerBatch : -1
        pictures = graph.placeholder(shape: [batch, 64, 64, 1] as [NSNumber], dataType: .float32, name: "pictures")
        asked = graph.placeholder(shape: [many, 64, 64, 1] as [NSNumber], dataType: .float32, name: "asked")
        labels = graph.placeholder(shape: [batch, 1] as [NSNumber], dataType: .float32, name: "labels")
        dropoutMask = graph.placeholder(shape: [batch, 64] as [NSNumber], dataType: .float32, name: "dropout")
        decay = graph.placeholder(shape: [1], dataType: .float32, name: "decay")
        stepSize = graph.placeholder(shape: [1], dataType: .float32, name: "stepSize")
        beta1 = graph.placeholder(shape: [1], dataType: .float32, name: "beta1")
        oneMinusBeta1 = graph.placeholder(shape: [1], dataType: .float32, name: "oneMinusBeta1")
        secondCorrection = graph.placeholder(shape: [1], dataType: .float32, name: "secondCorrection")

        // Starting values, as PyTorch draws them: uniform in +-1/sqrt(inputs of one unit).
        func variable(_ shape: [Int], bound: Float, name: String) -> MPSGraphTensor {
            let values = (0..<shape.reduce(1, *)).map { _ in random.uniform(-bound, bound) }
            return graph.variable(with: Self.data(values), shape: shape as [NSNumber], dataType: .float32, name: name)
        }
        func constant(_ shape: [Int], _ value: Float, name: String) -> MPSGraphTensor {
            let values = [Float](repeating: value, count: shape.reduce(1, *))
            return graph.variable(with: Self.data(values), shape: shape as [NSNumber], dataType: .float32, name: name)
        }
        for stage in 0..<4 {
            let inputs = Self.channels[stage], outputs = Self.channels[stage + 1]
            convolutions.append(variable([3, 3, inputs, outputs], bound: 1 / Float(9 * inputs).squareRoot(), name: "conv\(stage)"))
            gammas.append(constant([1, 1, 1, outputs], 1, name: "gamma\(stage)"))
            betas.append(constant([1, 1, 1, outputs], 0, name: "beta\(stage)"))
            runningMeans.append(constant([1, 1, 1, outputs], 0, name: "mean\(stage)"))
            runningVariances.append(constant([1, 1, 1, outputs], 1, name: "variance\(stage)"))
        }
        linear = variable([64, 1], bound: 1 / 8, name: "linear")
        bias = variable([1], bound: 1 / 8, name: "bias")

        build()
    }

    private func build() {
        // The preprocessing of model.py: every picture gets the same average brightness
        // (0) and the same contrast (1).
        func prepare(_ input: MPSGraphTensor) -> MPSGraphTensor {
            let average = graph.mean(of: input, axes: [1, 2, 3], name: nil)
            let centred = graph.subtraction(input, average, name: nil)
            let spread = graph.squareRoot(with: graph.mean(of: graph.square(with: centred, name: nil), axes: [1, 2, 3], name: nil), name: nil)
            return graph.division(centred, graph.addition(spread, graph.constant(1e-4, dataType: .float32), name: nil), name: nil)
        }

        let convolution = MPSGraphConvolution2DOpDescriptor(strideInX: 1, strideInY: 1, dilationRateInX: 1, dilationRateInY: 1,
                                                            groups: 1, paddingStyle: .TF_SAME, dataLayout: .NHWC, weightsLayout: .HWIO)!
        let pool = MPSGraphPooling2DOpDescriptor(kernelWidth: 2, kernelHeight: 2, strideInX: 2, strideInY: 2,
                                                 paddingStyle: .TF_VALID, dataLayout: .NHWC)!

        // The network twice over the same weights: once as it learns (the batch's own
        // statistics, dropout), once as it is used (the averages kept, no dropout).
        var learning = prepare(pictures), using = prepare(asked)
        var statistics: [(mean: MPSGraphTensor, variance: MPSGraphTensor)] = []
        for stage in 0..<4 {
            let detected = graph.convolution2D(learning, weights: convolutions[stage], descriptor: convolution, name: nil)
            let mean = graph.mean(of: detected, axes: [0, 1, 2], name: nil)
            let variance = graph.variance(of: detected, mean: mean, axes: [0, 1, 2], name: nil)
            statistics.append((mean, variance))
            let steady = graph.normalize(detected, mean: mean, variance: variance, gamma: gammas[stage], beta: betas[stage], epsilon: 1e-5, name: nil)
            learning = graph.maxPooling2D(withSourceTensor: graph.reLU(with: steady, name: nil), descriptor: pool, name: nil)

            let detectedInUse = graph.convolution2D(using, weights: convolutions[stage], descriptor: convolution, name: nil)
            let steadyInUse = graph.normalize(detectedInUse, mean: runningMeans[stage], variance: runningVariances[stage],
                                              gamma: gammas[stage], beta: betas[stage], epsilon: 1e-5, name: nil)
            using = graph.maxPooling2D(withSourceTensor: graph.reLU(with: steadyInUse, name: nil), descriptor: pool, name: nil)
        }

        func head(_ features: MPSGraphTensor, dropout: Bool) -> MPSGraphTensor {
            var summary = graph.reshape(graph.mean(of: features, axes: [1, 2], name: nil), shape: [-1, 64], name: nil)
            if dropout { summary = graph.multiplication(summary, dropoutMask, name: nil) }
            return graph.addition(graph.matrixMultiplication(primary: summary, secondary: linear, name: nil), bias, name: nil)
        }
        let score = head(learning, dropout: true)
        closed = graph.sigmoid(with: head(using, dropout: false), name: nil)

        // Binary cross-entropy on the raw score z, written so that it cannot overflow:
        // max(z, 0) - z * label + log(1 + exp(-|z|)).
        let one = graph.constant(1, dataType: .float32)
        let softPart = graph.logarithm(with: graph.addition(one, graph.exponent(with: graph.negative(with: graph.absolute(with: score, name: nil), name: nil), name: nil), name: nil), name: nil)
        let perPicture = graph.addition(graph.subtraction(graph.reLU(with: score, name: nil), graph.multiplication(score, labels, name: nil), name: nil), softPart, name: nil)
        loss = graph.mean(of: perPicture, axes: [0, 1], name: nil)

        // Backpropagation: MPSGraph derives the gradient of the loss for every weight.
        let trained = convolutions + gammas + betas + [linear!, bias!]
        let gradients = graph.gradients(of: loss, with: trained, name: nil)
        gradientTensors = trained.compactMap { gradients[$0] }

        // AdamW, one weight tensor at a time (same formula as torch.optim.AdamW).
        let beta2 = graph.constant(0.999, dataType: .float32), oneMinusBeta2 = graph.constant(0.001, dataType: .float32)
        let epsilon = graph.constant(1e-8, dataType: .float32)
        for weights in trained {
            guard let gradient = gradients[weights] else { fatalError("no gradient for \(weights.operation.name)") }
            let shape = weights.shape!
            let zeros = Self.data([Float](repeating: 0, count: shape.map(\.intValue).reduce(1, *)))
            let momentum = graph.variable(with: zeros, shape: shape, dataType: .float32, name: nil)
            let velocity = graph.variable(with: zeros, shape: shape, dataType: .float32, name: nil)
            let newMomentum = graph.addition(graph.multiplication(beta1, momentum, name: nil),
                                             graph.multiplication(oneMinusBeta1, gradient, name: nil), name: nil)
            let newVelocity = graph.addition(graph.multiplication(beta2, velocity, name: nil),
                                             graph.multiplication(oneMinusBeta2, graph.square(with: gradient, name: nil), name: nil), name: nil)
            let denominator = graph.addition(graph.multiplication(graph.squareRoot(with: newVelocity, name: nil), secondCorrection, name: nil), epsilon, name: nil)
            let shrunk = graph.multiplication(weights, graph.subtraction(one, decay, name: nil), name: nil)
            let moved = graph.subtraction(shrunk, graph.multiplication(stepSize, graph.division(newMomentum, denominator, name: nil), name: nil), name: nil)
            updates += [graph.assign(momentum, tensor: newMomentum, name: nil),
                        graph.assign(velocity, tensor: newVelocity, name: nil),
                        graph.assign(weights, tensor: moved, name: nil)]
        }
        // The averages batch normalisation uses once training is over: a tenth of each
        // new batch's statistics enters them.
        let keep = graph.constant(0.9, dataType: .float32), take = graph.constant(0.1, dataType: .float32)
        for stage in 0..<4 {
            updates.append(graph.assign(runningMeans[stage], tensor: graph.addition(
                graph.multiplication(keep, runningMeans[stage], name: nil), graph.multiplication(take, statistics[stage].mean, name: nil), name: nil), name: nil))
            updates.append(graph.assign(runningVariances[stage], tensor: graph.addition(
                graph.multiplication(keep, runningVariances[stage], name: nil), graph.multiplication(take, statistics[stage].variance, name: nil), name: nil), name: nil))
        }
    }

    // MARK: - Training

    /// The learning rate and beta1 of one step, as `OneCycleLR(max_lr=2e-3)` gives them.
    static func oneCycle(step: Int, total: Int) -> (rate: Double, beta1: Double) {
        let peak = 2e-3, start = peak / 25, end = start / 1e4
        let turn = 0.3 * Double(total) - 1
        func anneal(_ from: Double, _ to: Double, _ fraction: Double) -> Double {
            to + (from - to) / 2 * (cos(.pi * fraction) + 1)
        }
        if Double(step) <= turn {
            let fraction = Double(step) / turn
            return (anneal(start, peak, fraction), anneal(0.95, 0.85, fraction))
        }
        let fraction = (Double(step) - turn) / (Double(total - 1) - turn)
        return (anneal(peak, end, fraction), anneal(0.85, 0.95, fraction))
    }

    /// Trains on `count` pictures (`images`: count x 4096 grey values; `labels`: count).
    /// Returns the training loss of each epoch.
    @discardableResult
    func train(images: UnsafePointer<Float>, labels: [Float], epochs: Int, seed: UInt64,
               progress: ((Int, Float) -> Void)? = nil) -> [Float] {
        let count = labels.count, pixels = Pictures.pixels
        let stepsPerEpoch = (count + Self.batchSize - 1) / Self.batchSize
        let totalSteps = epochs * stepsPerEpoch
        var random = Random(seed: seed)
        // With fixed shapes every step holds 128 pictures: the last step of an epoch is
        // filled up with pictures from its start, altered another way.
        let shown = Self.fixedShapes ? stepsPerEpoch * Self.batchSize : count
        var altered = [Float](repeating: 0, count: shown * pixels)
        var shuffledLabels = [Float](repeating: 0, count: shown)
        var losses: [Float] = []
        var step = 0
        let weightDecay = 1e-4, beta2 = 0.999

        for epoch in 0..<epochs {
            // A new order and a new alteration of every picture, each epoch.
            var order = Array(0..<count)
            for i in stride(from: count - 1, to: 0, by: -1) { order.swapAt(i, random.below(i + 1)) }
            let epochSeed = random.next()
            let altering = Date()
            altered.withUnsafeMutableBufferPointer { buffer in
                let target = UnsafeMutablePointerBox(buffer.baseAddress!)
                let source = UnsafePointerBox(images)
                DispatchQueue.concurrentPerform(iterations: shown) { position in
                    var own = Random(seed: epochSeed ^ (UInt64(position) &* 0x9E37_79B9_7F4A_7C15))
                    Augment.apply(source.pointer + order[position % count] * pixels, into: target.pointer + position * pixels, random: &own)
                }
            }
            for position in 0..<shown { shuffledLabels[position] = labels[order[position % count]] }
            secondsAltering += Date().timeIntervalSince(altering)

            var total: Float = 0
            for start in stride(from: 0, to: shown, by: Self.batchSize) {
                let size = min(Self.batchSize, shown - start)
                let (rate, momentum) = Self.oneCycle(step: step, total: totalSteps)
                step += 1
                let mask = (0..<size * 64).map { _ in random.uniform() < 0.2 ? Float(0) : Float(1.25) }
                let feeds: [MPSGraphTensor: MPSGraphTensorData] = altered.withUnsafeBufferPointer { buffer in
                    [
                        pictures: tensor(UnsafeRawPointer(buffer.baseAddress! + start * pixels), count: size * pixels, shape: [size, 64, 64, 1]),
                        self.labels: tensor(Array(shuffledLabels[start..<start + size]), shape: [size, 1]),
                        dropoutMask: tensor(mask, shape: [size, 64]),
                        decay: tensor([Float(rate * weightDecay)], shape: [1]),
                        stepSize: tensor([Float(rate / (1 - pow(momentum, Double(step))))], shape: [1]),
                        beta1: tensor([Float(momentum)], shape: [1]),
                        oneMinusBeta1: tensor([Float(1 - momentum)], shape: [1]),
                        secondCorrection: tensor([Float(1 / (1 - pow(beta2, Double(step))).squareRoot())], shape: [1]),
                    ]
                }
                let before = Date()
                let result = run(feeds, [loss], updates)
                var value: Float = 0
                result[loss]!.mpsndarray().readBytes(&value, strideBytes: nil)
                total += value * Float(size)
                secondsOnGPU += Date().timeIntervalSince(before)
            }
            losses.append(total / Float(shown))
            progress?(epoch + 1, losses.last!)
        }
        return losses
    }

    /// Where does a training step's time go? Times the same batch four ways.
    func benchmark() {
        let size = Self.batchSize
        let feeds: [MPSGraphTensor: MPSGraphTensorData] = [
            pictures: tensor((0..<size * 4096).map { Float($0 % 97) / 97 }, shape: [size, 64, 64, 1]),
            labels: tensor((0..<size).map { Float($0 % 2) }, shape: [size, 1]),
            dropoutMask: tensor([Float](repeating: 1, count: size * 64), shape: [size, 64]),
            decay: tensor([0], shape: [1]), stepSize: tensor([1e-4], shape: [1]), beta1: tensor([0.9], shape: [1]),
            oneMinusBeta1: tensor([0.1], shape: [1]), secondCorrection: tensor([1], shape: [1]),
        ]
        func time(_ name: String, _ targets: [MPSGraphTensor], _ operations: [MPSGraphOperation]?) {
            _ = run(feeds, targets, operations)
            let start = Date()
            for _ in 0..<40 { _ = run(feeds, targets, operations) }
            print(String(format: "    %@ %.1f ms a step", name.padding(toLength: 46, withPad: " ", startingAt: 0), Date().timeIntervalSince(start) / 40 * 1000))
        }
        time("forward only (loss)", [loss], nil)
        time("forward + gradients", [loss] + gradientTensors, nil)
        // Which layer's gradient costs the time? Ask for one layer's at a time
        // (the gradient of an early layer needs the backward pass through all later ones).
        for stage in (0..<4).reversed() {
            let only = graph.gradients(of: loss, with: [convolutions[stage]], name: nil)[convolutions[stage]]!
            time("gradient of convolution \(stage) alone", [loss, only], nil)
        }
        time("the whole step (50 variables stored)", [loss], updates)
    }

    // MARK: - Using the model

    /// The probability "closed" of each picture, with no alteration.
    func predict(images: UnsafePointer<Float>, count: Int) -> [Float] {
        var answers = [Float](repeating: 0, count: count)
        let pixels = Pictures.pixels
        var padded = [Float](repeating: 0, count: Self.answerBatch * pixels), out = [Float](repeating: 0, count: Self.answerBatch)
        for start in stride(from: 0, to: count, by: Self.answerBatch) {
            let size = min(Self.answerBatch, count - start)
            if Self.fixedShapes {
                padded.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: images + start * pixels, count: size * pixels) }
                let feed = tensor(padded, shape: [Self.answerBatch, 64, 64, 1])
                run([asked: feed], [closed])[closed]!.mpsndarray().readBytes(&out, strideBytes: nil)
                for i in 0..<size { answers[start + i] = out[i] }
            } else {
                let feed = tensor(UnsafeRawPointer(images + start * pixels), count: size * pixels, shape: [size, 64, 64, 1])
                let result = run([asked: feed], [closed])
                answers.withUnsafeMutableBufferPointer { result[closed]!.mpsndarray().readBytes($0.baseAddress! + start, strideBytes: nil) }
            }
        }
        return answers
    }

    /// The trained numbers, with each batch normalisation folded into its convolution:
    /// what a model that only answers needs. Convolutions as (out, in, 3, 3), then biases.
    func foldedWeights() -> [(name: String, shape: [Int], values: [Float])] {
        let tensors = convolutions + gammas + betas + runningMeans + runningVariances + [linear!, bias!]
        let result = run([:], tensors)
        func values(_ tensor: MPSGraphTensor) -> [Float] {
            var out = [Float](repeating: 0, count: tensor.shape!.map(\.intValue).reduce(1, *))
            result[tensor]!.mpsndarray().readBytes(&out, strideBytes: nil)
            return out
        }
        var folded: [(name: String, shape: [Int], values: [Float])] = []
        for stage in 0..<4 {
            let inputs = Self.channels[stage], outputs = Self.channels[stage + 1]
            let kernel = values(convolutions[stage])   // (3, 3, in, out)
            let gamma = values(gammas[stage]), beta = values(betas[stage])
            let mean = values(runningMeans[stage]), variance = values(runningVariances[stage])
            var weights = [Float](repeating: 0, count: outputs * inputs * 9), biases = [Float](repeating: 0, count: outputs)
            for o in 0..<outputs {
                let scale = gamma[o] / (variance[o] + 1e-5).squareRoot()
                biases[o] = beta[o] - mean[o] * scale
                for i in 0..<inputs { for y in 0..<3 { for x in 0..<3 {
                    weights[((o * inputs + i) * 3 + y) * 3 + x] = kernel[((y * 3 + x) * inputs + i) * outputs + o] * scale
                } } }
            }
            folded.append(("conv\(stage).weight", [outputs, inputs, 3, 3], weights))
            folded.append(("conv\(stage).bias", [outputs], biases))
        }
        folded.append(("linear.weight", [1, 64], values(linear)))
        folded.append(("linear.bias", [1], values(bias)))
        return folded
    }

    // MARK: - Feeding numbers to the GPU

    private static func data(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func tensor(_ values: [Float], shape: [Int]) -> MPSGraphTensorData {
        MPSGraphTensorData(device: device, data: Self.data(values), shape: shape as [NSNumber], dataType: .float32)
    }

    private func tensor(_ bytes: UnsafeRawPointer, count: Int, shape: [Int]) -> MPSGraphTensorData {
        MPSGraphTensorData(device: device, data: Data(bytes: bytes, count: count * MemoryLayout<Float>.stride),
                           shape: shape as [NSNumber], dataType: .float32)
    }
}

struct UnsafePointerBox: @unchecked Sendable {
    let pointer: UnsafePointer<Float>
    init(_ pointer: UnsafePointer<Float>) { self.pointer = pointer }
}
