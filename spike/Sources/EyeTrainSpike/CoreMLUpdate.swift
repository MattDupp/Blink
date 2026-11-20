import CoreML
import Foundation

/// SPIKE, second candidate: Core ML's own on-device training (`MLUpdateTask`) on the
/// updatable template made by coreml_update_template.py.
///
/// The pictures are handed over one at a time through `MLBatchProvider`. Each time Core
/// ML asks for a picture it gets a newly altered copy, which is how augmentation is
/// fitted into an API that has none.
final class AlteredPictures: NSObject, MLBatchProvider, @unchecked Sendable {
    private let images: [Float]
    private let labels: [Float]
    private let seed: UInt64
    private let asked = Counter()

    init(images: [Float], labels: [Float], seed: UInt64) {
        self.images = images
        self.labels = labels
        self.seed = seed
    }

    var count: Int { labels.count }
    var timesAsked: Int { asked.value }

    func features(at index: Int) -> MLFeatureProvider {
        asked.add()
        let pixels = Pictures.pixels
        // A different alteration each time the same picture is asked for.
        var random = Random(seed: seed ^ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(asked.value) << 32))
        let picture = try! MLMultiArray(shape: [1, 64, 64], dataType: .float32)
        images.withUnsafeBufferPointer { source in
            picture.withUnsafeMutableBytes { target, _ in
                Augment.apply(source.baseAddress! + index * pixels, into: target.bindMemory(to: Float.self).baseAddress!, random: &random)
            }
        }
        let label = try! MLMultiArray(shape: [1], dataType: .int32)
        label[0] = NSNumber(value: Int32(labels[index]))
        return try! MLDictionaryFeatureProvider(dictionary: ["eye": picture, "probabilities_true": label])
    }
}

enum CoreMLUpdate {

    /// Trains the template at `template` and returns the probability "closed" of `asked`.
    static func run(template: URL, images: [Float], labels: [Float], asked: [Float], askedCount: Int,
                    epochs: Int, seed: UInt64, cosineRate: Bool) throws -> (closed: [Float], losses: [Float], note: String) {
        let provider = AlteredPictures(images: images, labels: labels, seed: seed)
        let configuration = MLModelConfiguration()
        configuration.parameters = [MLParameterKey.epochs: epochs, MLParameterKey.seed: Int(seed % 10_000)]

        var losses: [Float] = []
        var trained: URL?
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        let handlers = MLUpdateProgressHandlers(forEvents: [.epochEnd], progressHandler: { context in
            losses.append((context.metrics[.lossValue] as? NSNumber)?.floatValue ?? .nan)
            // The task has no schedule of its own; the rate can be changed between epochs.
            var parameters: [MLParameterKey: Any] = [:]
            if cosineRate {
                let fraction = Double(losses.count) / Double(epochs)
                parameters[.learningRate] = 1e-5 + (1e-3 - 1e-5) * 0.5 * (1 + cos(.pi * fraction))
            }
            context.task.resume(withParameters: parameters)
        }, completionHandler: { context in
            if let error = context.task.error {
                failure = error
            } else {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("updated-\(UUID().uuidString).mlmodelc")
                do { try context.model.write(to: url); trained = url } catch { failure = error }
            }
            done.signal()
        })
        let task = try MLUpdateTask(forModelAt: template, trainingData: provider, configuration: configuration, progressHandlers: handlers)
        task.resume()
        done.wait()
        if let failure { throw failure }
        guard let trained else { throw NSError(domain: "spike", code: 1) }
        defer { try? FileManager.default.removeItem(at: trained) }

        let using = MLModelConfiguration()
        using.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: trained, configuration: using)
        var closed = [Float](repeating: 0, count: askedCount)
        for i in 0..<askedCount {
            let picture = try MLMultiArray(shape: [1, 64, 64], dataType: .float32)
            asked.withUnsafeBufferPointer { source in
                picture.withUnsafeMutableBytes { target, _ in
                    target.bindMemory(to: Float.self).baseAddress!.update(from: source.baseAddress! + i * Pictures.pixels, count: Pictures.pixels)
                }
            }
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["eye": picture]))
            closed[i] = output.featureValue(for: "probabilities")!.multiArrayValue![1].floatValue
        }
        let note = "pictures handed over \(provider.timesAsked) times for \(epochs) epochs of \(labels.count)"
        return (closed, losses, note)
    }
}
