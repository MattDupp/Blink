import CoreML
import CreateML
import Foundation

/// SPIKE, third candidate: Create ML's image classifier. It does not train a network on
/// the pictures. It runs each picture through a large general-purpose network Apple ships
/// in macOS ("scene print"), and trains a small classifier on what comes out.
enum CreateMLRun {

    static func run(pictures: [String], labels: [Int], train: [Int], asked: [Int]) throws
        -> (closed: [Float], trainSeconds: Double, millisecondsPerAnswer: Double, note: String) {
        var byLabel: [String: [URL]] = ["open": [], "closed": []]
        for i in train { byLabel[labels[i] == 1 ? "closed" : "open"]!.append(URL(fileURLWithPath: pictures[i])) }

        let started = Date()
        let parameters = MLImageClassifier.ModelParameters(
            validation: .none, maxIterations: 25, augmentation: [],
            algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor))
        let classifier = try MLImageClassifier(trainingData: .filesByLabel(byLabel), parameters: parameters)
        let trainSeconds = Date().timeIntervalSince(started)

        let model = classifier.model
        let input = model.modelDescription.inputDescriptionsByName.first { $0.value.type == .image }!
        let probabilities = model.modelDescription.predictedProbabilitiesName ?? "classLabelProbs"
        var closed = [Float](repeating: 0, count: asked.count)
        let answering = Date()
        for (n, i) in asked.enumerated() {
            let value = try MLFeatureValue(imageAt: URL(fileURLWithPath: pictures[i]), constraint: input.value.imageConstraint!, options: nil)
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: value]))
            let answer = output.featureValue(for: probabilities)?.dictionaryValue as? [String: NSNumber]
            closed[n] = answer?["closed"]?.floatValue ?? 0
        }
        let perAnswer = Date().timeIntervalSince(answering) / Double(max(asked.count, 1)) * 1000
        let size = input.value.imageConstraint.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "?"
        return (closed, trainSeconds, perAnswer, "model input \(size); training accuracy \(100 - classifier.trainingMetrics.classificationError * 100)%")
    }
}
