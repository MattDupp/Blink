import Foundation
import Metal
import MetalPerformanceShadersGraph

/// Trains EyeNet on this Mac, in Swift: what `training/learning.py` does in Python.
///
/// It is written with MPSGraph, Apple's framework for running AND differentiating a network
/// on the Mac's graphics processor. PyTorch's own "mps" device is built on it, so this is
/// the Python route's engine without Python: nothing to install, nothing to ship.
///
/// Same network (`training/model.py`): four stages of 3x3 convolution, batch normalisation,
/// ReLU and 2x2 max pool, then an average, dropout and one weighted sum. Same training:
/// AdamW, a one-cycle learning rate, binary cross-entropy, 128 pictures a step, 30 passes.
///
/// MEASURED against the Python route (2026-11-20, the same pictures and the same splits,
/// scored by training/evaluate.py's own functions; M5 Pro):
///
///                         pictures right, session never seen    blinks found / false, 13 seeds    one training
///     Python (PyTorch)    99.68%                                936 of 936 / 6                    11 s
///     this trainer        99.62%                                936 of 936 / 7                    19 s
///     Core ML's own       98.39%                                211 of 216 / 7 (3 seeds)          37 s
///
/// Core ML's on-device training (MLUpdateTask) can only train convolutions and
/// fully-connected layers: batch normalisation, dropout and the learning-rate schedule are
/// lost, and it falls under the bar of 72 of 72 blinks. `make compare` runs the comparison
/// again (docs/DEVELOPMENT.md).
public final class EyeTrainer {

    static let channels = EyeNetWeights.channels
    static let batchSize = 128
    static let answerBatch = 512
    static let pixels = EyeNetwork.pixels

    /// A Mac with no graphics processor that Metal can use cannot train (a virtual machine).
    public static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    private let graph = MPSGraph()
    private let device: MPSGraphDevice
    private let queue: MTLCommandQueue

    // What is fed at every step.
    private let pictures: MPSGraphTensor      // (N, 64, 64, 1) grey, 0...1
    private let asked: MPSGraphTensor         // the same, for answering
    private let labels: MPSGraphTensor        // (N, 1): 1 = closed
    private let dropoutMask: MPSGraphTensor   // (N, 64): 0, or 1 / 0.8
    private let decay, stepSize, beta1, oneMinusBeta1, secondCorrection: MPSGraphTensor

    // The network's numbers, as the graph sees them...
    private var convolutions: [MPSGraphTensor] = []
    private var gammas: [MPSGraphTensor] = [], betas: [MPSGraphTensor] = []
    private var runningMeans: [MPSGraphTensor] = [], runningVariances: [MPSGraphTensor] = []
    private var linear: MPSGraphTensor!, bias: MPSGraphTensor!

    /// ...and their values, kept on the graphics processor between two steps.
    ///
    /// WHERE THE WEIGHTS LIVE. MPSGraph can keep such numbers itself, in "variables" that a
    /// step reads and assigns. The first version did that, and twice in about 280 trainings
    /// the framework ended the process from its own queue: `MPSGraphVariable.mm:69: failed
    /// assertion 'multi-device variable handling not correctly implemented'` (2026-11-20 and
    /// 21, both on a busy Mac). So nothing is a variable here: every number that outlives a
    /// step enters it as an input and leaves it as an output, which is fed to the next step
    /// as it is, without leaving the graphics processor. PyTorch's "mps" device works the
    /// same way. The code that asserted is no longer reached; that this ends the failure
    /// has NOT been measured (docs/LESSONS.md, number 8, says why the measurement stopped).
    private var state: [MPSGraphTensor: MPSGraphTensorData] = [:]
    /// What each step produces for each of them: (the input, its new value).
    private var next: [(input: MPSGraphTensor, output: MPSGraphTensor)] = []
    /// What answering needs to be fed.
    private var inUse: [MPSGraphTensor] = []

    private var loss: MPSGraphTensor!
    private var closed: MPSGraphTensor!       // the answer in use: probability closed

    /// Runs the graph, everything on the graphics processor.
    ///
    /// MPSGraph's default ("optimisation level 1") may place parts of a graph on the
    /// processor or the Neural Engine. One run of the spike ended inside the framework with
    /// "multi-device variable handling not correctly implemented" (2026-11-20; it did not
    /// come back in 170 later trainings, and its cause is not known). Level 0 keeps
    /// everything on one device, and costs nothing: 18.7 s a training either way.
    private func run(_ feeds: [MPSGraphTensor: MPSGraphTensorData],
                     _ targets: [MPSGraphTensor]) -> [MPSGraphTensor: MPSGraphTensorData] {
        let compilation = MPSGraphCompilationDescriptor()
        compilation.optimizationLevel = .level0
        let execution = MPSGraphExecutionDescriptor()
        execution.compilationDescriptor = compilation
        execution.waitUntilCompleted = true
        return graph.runAsync(with: queue, feeds: feeds, targetTensors: targets, targetOperations: nil,
                              executionDescriptor: execution)
    }

    /// Nil on a Mac where Metal has no device. `seed`: the same seed draws the same
    /// starting weights.
    public init?(seed: UInt64) {
        guard let metal = MTLCreateSystemDefaultDevice(), let queue = metal.makeCommandQueue() else { return nil }
        device = MPSGraphDevice(mtlDevice: metal)
        self.queue = queue
        var random = SeededRandom(seed: seed &* 7_919 &+ 13)

        pictures = graph.placeholder(shape: [-1, 64, 64, 1], dataType: .float32, name: "pictures")
        asked = graph.placeholder(shape: [-1, 64, 64, 1], dataType: .float32, name: "asked")
        labels = graph.placeholder(shape: [-1, 1], dataType: .float32, name: "labels")
        dropoutMask = graph.placeholder(shape: [-1, 64], dataType: .float32, name: "dropout")
        decay = graph.placeholder(shape: [1], dataType: .float32, name: "decay")
        stepSize = graph.placeholder(shape: [1], dataType: .float32, name: "stepSize")
        beta1 = graph.placeholder(shape: [1], dataType: .float32, name: "beta1")
        oneMinusBeta1 = graph.placeholder(shape: [1], dataType: .float32, name: "oneMinusBeta1")
        secondCorrection = graph.placeholder(shape: [1], dataType: .float32, name: "secondCorrection")

        // Starting values, as PyTorch draws them: uniform in +-1 / sqrt(inputs of one unit).
        func variable(_ shape: [Int], bound: Float, name: String) -> MPSGraphTensor {
            kept((0..<shape.reduce(1, *)).map { _ in random.uniform(-bound, bound) }, shape: shape, name: name)
        }
        func constant(_ shape: [Int], _ value: Float, name: String) -> MPSGraphTensor {
            kept([Float](repeating: value, count: shape.reduce(1, *)), shape: shape, name: name)
        }
        for stage in 0..<EyeNetWeights.stages {
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

    /// A tensor whose value outlives a step: an input of the graph, with its value kept
    /// beside it.
    private func kept(_ values: [Float], shape: [Int], name: String?) -> MPSGraphTensor {
        let input = graph.placeholder(shape: shape as [NSNumber], dataType: .float32, name: name)
        state[input] = tensor(values, shape: shape)
        return input
    }

    /// The value `tensor` has after a step.
    private func keep(_ value: MPSGraphTensor, as tensor: MPSGraphTensor) {
        next.append((tensor, value))
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
        for stage in 0..<EyeNetWeights.stages {
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

        // The loss: binary cross-entropy on the raw score z, written so that it cannot
        // overflow:  max(z, 0) - z * label + log(1 + exp(-|z|)).
        let one = graph.constant(1, dataType: .float32)
        let softPart = graph.logarithm(with: graph.addition(one, graph.exponent(with: graph.negative(with: graph.absolute(with: score, name: nil), name: nil), name: nil), name: nil), name: nil)
        let perPicture = graph.addition(graph.subtraction(graph.reLU(with: score, name: nil), graph.multiplication(score, labels, name: nil), name: nil), softPart, name: nil)
        loss = graph.mean(of: perPicture, axes: [0, 1], name: nil)

        // Backpropagation: MPSGraph derives, for every weight, how the loss changes with it.
        let trained = convolutions + gammas + betas + [linear!, bias!]
        let gradients = graph.gradients(of: loss, with: trained, name: nil)

        // AdamW, one weight tensor at a time (the formula of torch.optim.AdamW).
        let beta2 = graph.constant(0.999, dataType: .float32), oneMinusBeta2 = graph.constant(0.001, dataType: .float32)
        let epsilon = graph.constant(1e-8, dataType: .float32)
        for weights in trained {
            guard let gradient = gradients[weights], let shape = weights.shape?.map(\.intValue) else { continue }
            let zeros = [Float](repeating: 0, count: shape.reduce(1, *))
            let momentum = kept(zeros, shape: shape, name: nil)
            let velocity = kept(zeros, shape: shape, name: nil)
            let newMomentum = graph.addition(graph.multiplication(beta1, momentum, name: nil),
                                             graph.multiplication(oneMinusBeta1, gradient, name: nil), name: nil)
            let newVelocity = graph.addition(graph.multiplication(beta2, velocity, name: nil),
                                             graph.multiplication(oneMinusBeta2, graph.square(with: gradient, name: nil), name: nil), name: nil)
            let denominator = graph.addition(graph.multiplication(graph.squareRoot(with: newVelocity, name: nil), secondCorrection, name: nil), epsilon, name: nil)
            let shrunk = graph.multiplication(weights, graph.subtraction(one, decay, name: nil), name: nil)
            let moved = graph.subtraction(shrunk, graph.multiplication(stepSize, graph.division(newMomentum, denominator, name: nil), name: nil), name: nil)
            keep(newMomentum, as: momentum)
            keep(newVelocity, as: velocity)
            keep(moved, as: weights)
        }
        // The averages batch normalisation uses once training is over: a tenth of each
        // new batch's statistics enters them.
        let keep = graph.constant(0.9, dataType: .float32), take = graph.constant(0.1, dataType: .float32)
        for stage in 0..<EyeNetWeights.stages {
            self.keep(graph.addition(graph.multiplication(keep, runningMeans[stage], name: nil),
                                     graph.multiplication(take, statistics[stage].mean, name: nil), name: nil), as: runningMeans[stage])
            self.keep(graph.addition(graph.multiplication(keep, runningVariances[stage], name: nil),
                                     graph.multiplication(take, statistics[stage].variance, name: nil), name: nil), as: runningVariances[stage])
        }
        inUse = convolutions + gammas + betas + runningMeans + runningVariances + [linear!, bias!]
    }

    /// One step of training: runs the graph on `feeds`, moves every kept number to its
    /// new value, and returns the loss.
    ///
    /// THE POOL IS NOT A DETAIL. What the graph returns is handed over "autoreleased": it
    /// is only freed when the surrounding pool is emptied, and a program that just loops
    /// never empties one. Each step returns fifty arrays that live on the graphics
    /// processor. The first run of this version had no pool here, in three trainings side
    /// by side: within three minutes macOS could no longer create a graphics surface, the
    /// window server aborted twelve times in a row, and the Mac had to be forced off
    /// (2026-11-21, docs/LESSONS.md number 8). Arrays kept from every step are the likely
    /// cause; it was reasoned from the crash reports, not reproduced.
    /// With the pool, a step's arrays are freed as soon as the next step has replaced them.
    private func advance(_ feeds: [MPSGraphTensor: MPSGraphTensorData]) -> Float {
        autoreleasepool {
            var value: Float = 0
            // Each kept number goes in as it is and comes out one step older. What comes
            // out stays on the graphics processor: it is the next step's input, not a copy.
            let result = run(feeds.merging(state) { new, _ in new }, [loss] + next.map(\.output))
            for (input, output) in next {
                if let moved = result[output] { state[input] = moved }
            }
            result[loss]?.mpsndarray().readBytes(&value, strideBytes: nil)
            return value
        }
    }

    /// The kept numbers that answering, or reading the weights out, needs to be fed.
    private func fed(_ tensors: [MPSGraphTensor]) -> [MPSGraphTensor: MPSGraphTensorData] {
        var feeds: [MPSGraphTensor: MPSGraphTensorData] = [:]
        for tensor in tensors { feeds[tensor] = state[tensor] }
        return feeds
    }

    // MARK: - Training

    /// The learning rate and beta1 of one step: small, rising to 0.002 over the first
    /// 30% of the steps, then falling to almost nothing (`OneCycleLR` in PyTorch).
    static func oneCycle(step: Int, total: Int) -> (rate: Double, beta1: Double) {
        let peak = 2e-3, start = peak / 25, end = start / 1e4
        let turn = 0.3 * Double(total) - 1
        func anneal(_ from: Double, _ to: Double, _ fraction: Double) -> Double {
            to + (from - to) / 2 * (cos(.pi * fraction) + 1)
        }
        if Double(step) <= turn {
            let fraction = turn > 0 ? Double(step) / turn : 1
            return (anneal(start, peak, fraction), anneal(0.95, 0.85, fraction))
        }
        let fraction = (Double(step) - turn) / max(Double(total - 1) - turn, 1)
        return (anneal(peak, end, fraction), anneal(0.85, 0.95, fraction))
    }

    /// Trains on `labels.count` pictures (`images`: 4,096 brightness values each, 0...1;
    /// `labels`: 1 = closed). `progress` is called after each pass over the pictures, with
    /// the pass's number (from 1) and its average loss. Returns the loss of each pass.
    @discardableResult
    public func train(images: UnsafePointer<Float>, labels: [Float], epochs: Int, seed: UInt64,
                      progress: ((Int, Float) -> Void)? = nil) -> [Float] {
        let count = labels.count, pixels = Self.pixels
        guard count > 0, epochs > 0 else { return [] }
        let stepsPerEpoch = (count + Self.batchSize - 1) / Self.batchSize
        let totalSteps = epochs * stepsPerEpoch
        var random = SeededRandom(seed: seed)
        var altered = [Float](repeating: 0, count: count * pixels)
        var shuffledLabels = [Float](repeating: 0, count: count)
        var losses: [Float] = []
        var step = 0
        let weightDecay = 1e-4, beta2 = 0.999

        for epoch in 0..<epochs {
            // A new order and a new alteration of every picture, at each pass.
            var order = Array(0..<count)
            for i in stride(from: count - 1, to: 0, by: -1) { order.swapAt(i, random.below(i + 1)) }
            let epochSeed = random.next()
            altered.withUnsafeMutableBufferPointer { buffer in
                let target = SharedPointer(buffer.baseAddress!), source = SharedPointer(images)
                DispatchQueue.concurrentPerform(iterations: count) { position in
                    var own = SeededRandom(seed: epochSeed ^ (UInt64(position) &* 0x9E37_79B9_7F4A_7C15))
                    PictureAlteration.apply(source.pointer + order[position] * pixels, into: target.pointer + position * pixels, random: &own)
                }
            }
            for position in 0..<count { shuffledLabels[position] = labels[order[position]] }

            var total: Float = 0
            for start in stride(from: 0, to: count, by: Self.batchSize) {
                let size = min(Self.batchSize, count - start)
                let (rate, momentum) = Self.oneCycle(step: step, total: totalSteps)
                step += 1
                // Dropout: silence a fifth of the 64 numbers, and scale the others up.
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
                total += advance(feeds) * Float(size)
            }
            losses.append(total / Float(count))
            progress?(epoch + 1, losses[epoch])
        }
        return losses
    }

    // MARK: - Using what was learned

    /// The probability "closed" of each picture, with no alteration.
    public func predict(images: UnsafePointer<Float>, count: Int) -> [Float] {
        var answers = [Float](repeating: 0, count: count)
        let pixels = Self.pixels
        for start in stride(from: 0, to: count, by: Self.answerBatch) {
            let size = min(Self.answerBatch, count - start)
            autoreleasepool {                    // what the graph returns is freed batch by batch (see `advance`)
                let feed = tensor(UnsafeRawPointer(images + start * pixels), count: size * pixels, shape: [size, 64, 64, 1])
                let result = run(fed(inUse).merging([asked: feed]) { kept, _ in kept }, [closed])
                answers.withUnsafeMutableBufferPointer { result[closed]?.mpsndarray().readBytes($0.baseAddress! + start, strideBytes: nil) }
            }
        }
        return answers
    }

    /// The trained numbers, with each batch normalisation folded into its convolution:
    /// what a model that only answers needs (`EyeNetwork`).
    public func weights() throws -> EyeNetWeights {
        let result = state
        func values(_ tensor: MPSGraphTensor) -> [Float] {
            var out = [Float](repeating: 0, count: (tensor.shape ?? []).map(\.intValue).reduce(1, *))
            result[tensor]?.mpsndarray().readBytes(&out, strideBytes: nil)
            return out
        }
        var flat: [Float] = []
        for stage in 0..<EyeNetWeights.stages {
            let inputs = Self.channels[stage], outputs = Self.channels[stage + 1]
            let kernel = values(convolutions[stage])   // (3, 3, in, out), as MPSGraph keeps it
            let gamma = values(gammas[stage]), beta = values(betas[stage])
            let mean = values(runningMeans[stage]), variance = values(runningVariances[stage])
            var folded = [Float](repeating: 0, count: outputs * inputs * 9), biases = [Float](repeating: 0, count: outputs)
            for o in 0..<outputs {
                let scale = gamma[o] / (variance[o] + 1e-5).squareRoot()
                biases[o] = beta[o] - mean[o] * scale
                for i in 0..<inputs { for y in 0..<3 { for x in 0..<3 {
                    folded[((o * inputs + i) * 3 + y) * 3 + x] = kernel[((y * 3 + x) * inputs + i) * outputs + o] * scale
                } } }
            }
            flat += folded + biases
        }
        return try EyeNetWeights(flat: flat + values(linear) + values(bias))
    }

    // MARK: - Feeding numbers to the graphics processor

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
