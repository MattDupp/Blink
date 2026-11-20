import CoreML
import CoreGraphics
import CoreVideo
import Foundation

/// STAGE 2 of the pipeline: runs the trained model on one 64x64 eye picture.
///
/// The model was trained in Python and converted to Core ML (training/convert.py). Core ML
/// is part of macOS: this class loads the compiled model once and then asks it, for each
/// eye picture, "how sure are you that this eye is closed?".
public final class EyeClassifier {

    public enum ClassifierError: Error, CustomStringConvertible {
        case notAnEyeModel(String)
        case wrongPicture(String)

        public var description: String {
            switch self {
            case .notAnEyeModel(let what): return "This is not the eye model: \(what)."
            case .wrongPicture(let what): return "The eye picture cannot be given to the model: \(what)."
            }
        }
    }

    private let model: MLModel
    private let width: Int
    private let height: Int

    /// `compiledModel`: the EyeNet.mlmodelc folder made by training/convert.py.
    public init(compiledModel: URL) throws {
        let configuration = MLModelConfiguration()
        // Core ML can run a model on the CPU, the GPU or the Neural Engine. Sending work
        // to the GPU or the Neural Engine has a fixed cost per call that only pays off
        // for big models; ours has 60,000 weights and runs in a tenth of a millisecond
        // on the CPU.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: compiledModel, configuration: configuration)

        guard let input = model.modelDescription.inputDescriptionsByName["eye"]?.imageConstraint else {
            throw ClassifierError.notAnEyeModel("no picture input named 'eye'")
        }
        guard model.modelDescription.outputDescriptionsByName["closed"] != nil else {
            throw ClassifierError.notAnEyeModel("no output named 'closed'")
        }
        guard input.pixelFormatType == kCVPixelFormatType_32BGRA else {
            throw ClassifierError.notAnEyeModel("its picture input is not in the BGRA format")
        }
        width = input.pixelsWide
        height = input.pixelsHigh
    }

    /// The probability that the eye in this picture is closed: 0 = open, 1 = closed.
    ///
    /// The buffer must already be what the model declared (64x64, BGRA) - exactly what
    /// `EyeCropper.cropBuffer` produces. Handing it over as it is, with no conversion,
    /// is what keeps this call at about 0.1 ms.
    public func closedProbability(of eye: CVPixelBuffer) throws -> Double {
        guard CVPixelBufferGetWidth(eye) == width, CVPixelBufferGetHeight(eye) == height,
              CVPixelBufferGetPixelFormatType(eye) == kCVPixelFormatType_32BGRA else {
            throw ClassifierError.wrongPicture("expected \(width) x \(height) BGRA, got "
                + "\(CVPixelBufferGetWidth(eye)) x \(CVPixelBufferGetHeight(eye))")
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["eye": MLFeatureValue(pixelBuffer: eye)])
        let output = try model.prediction(from: input)
        guard let values = output.featureValue(for: "closed")?.multiArrayValue, values.count > 0 else {
            throw ClassifierError.notAnEyeModel("the output 'closed' is empty")
        }
        return values[0].doubleValue
    }

    /// The same, for a picture read from disk (tests and tools; not used per frame).
    public func closedProbability(of image: CGImage) throws -> Double {
        guard let buffer = EyeCropper.buffer(from: image) else {
            throw ClassifierError.wrongPicture("it could not be copied into a pixel buffer")
        }
        return try closedProbability(of: buffer)
    }
}
