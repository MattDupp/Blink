import CoreML
import CoreGraphics
import Foundation

/// STAGE 2 of the pipeline: runs the trained model on one 64x64 eye picture.
///
/// The model was trained in Python and converted to Core ML (training/convert.py). Core ML
/// is part of macOS: this class loads the compiled model once and then asks it, for each
/// eye picture, "how sure are you that this eye is closed?".
public final class EyeClassifier {

    public enum ClassifierError: Error, CustomStringConvertible {
        case notAnEyeModel(String)

        public var description: String {
            switch self {
            case .notAnEyeModel(let what): return "This is not the eye model: \(what)."
            }
        }
    }

    private let model: MLModel
    /// The picture format the model declared for its input (64x64, colour). Core ML
    /// uses it to convert whatever picture we hand over into exactly that format.
    private let constraint: MLImageConstraint

    /// `compiledModel`: the EyeNet.mlmodelc folder made by training/convert.py.
    public init(compiledModel: URL) throws {
        let configuration = MLModelConfiguration()
        // Core ML can run a model on the CPU, the GPU or the Neural Engine. Sending work
        // to the GPU or the Neural Engine has a fixed cost per call that only pays off
        // for big models; ours has 60,000 weights and runs in a fraction of a millisecond
        // on the CPU.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: compiledModel, configuration: configuration)

        guard let input = model.modelDescription.inputDescriptionsByName["eye"]?.imageConstraint else {
            throw ClassifierError.notAnEyeModel("no picture input named 'eye'")
        }
        guard model.modelDescription.outputDescriptionsByName["closed"] != nil else {
            throw ClassifierError.notAnEyeModel("no output named 'closed'")
        }
        constraint = input
    }

    /// The probability that the eye in this picture is closed: 0 = open, 1 = closed.
    public func closedProbability(of eye: CGImage) throws -> Double {
        let picture = try MLFeatureValue(cgImage: eye, constraint: constraint, options: nil)
        let input = try MLDictionaryFeatureProvider(dictionary: ["eye": picture])
        let output = try model.prediction(from: input)
        guard let values = output.featureValue(for: "closed")?.multiArrayValue, values.count > 0 else {
            throw ClassifierError.notAnEyeModel("the output 'closed' is empty")
        }
        return values[0].doubleValue
    }
}
