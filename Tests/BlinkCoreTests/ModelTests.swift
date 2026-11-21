import Foundation
import Testing
@testable import BlinkCore

/// The trained model, run from Swift, against the answers Python computed for the same
/// pictures (training/convert.py writes them to models/eyenet_reference.json).
///
/// This is the test that catches a model fed the wrong way: colours in another order,
/// values on another scale, a resize in between. None of those crash; the model would
/// simply answer worse, and nobody would know why.
///
/// The model and the pictures are personal data and are not in the repository, so these
/// tests only run on a machine where `make train` has been done.
@Suite("The model in Swift")
struct ModelTests {

    private struct Reference: Decodable {
        let file: String
        let label: String
        let closed: Double
    }

    static let modelURL = Fixture.models.appendingPathComponent("EyeNet.mlmodelc", isDirectory: true)
    static let referenceURL = Fixture.models.appendingPathComponent("eyenet_reference.json")
    /// The same model in the app's own format (training/convert.py writes both).
    static let weightsURL = Fixture.models.appendingPathComponent("eyenet.weights")
    static let available = FileManager.default.fileExists(atPath: modelURL.path)
        && FileManager.default.fileExists(atPath: referenceURL.path)
    static let weightsAvailable = FileManager.default.fileExists(atPath: weightsURL.path)
        && FileManager.default.fileExists(atPath: referenceURL.path)

    @Test("Swift gives Python's answers on real pictures", .enabled(if: available, "no trained model on this machine"))
    func matchesPython() throws {
        let classifier = try EyeClassifier(compiledModel: Self.modelURL)
        let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: Self.referenceURL))

        var compared = 0, worst = 0.0, wrongLabel = 0
        for reference in references {
            // A picture may have been cleaned out of the dataset since the file was written.
            guard let picture = PNGFile.read(Fixture.dataHome.appendingPathComponent(reference.file)) else { continue }
            let answer = try classifier.closedProbability(of: picture)
            compared += 1
            worst = max(worst, abs(answer - reference.closed))
            if (answer > 0.5) != (reference.label == "closed") { wrongLabel += 1 }
        }
        #expect(compared >= 10, "only \(compared) reference pictures were found")
        #expect(worst < 0.01, "largest difference \(worst)")
        #expect(wrongLabel == 0)
    }

    /// The models trained in the app are run by `EyeNetwork`, the network written out in
    /// Swift. Given the Python model's weights it must give the Python model's answers:
    /// that is what says its arithmetic is the network's, and not something close to it.
    @Test("The network written in Swift gives Python's answers on real pictures",
          .enabled(if: weightsAvailable, "no model in the app's format on this machine (make train writes it)"))
    func networkInSwiftMatchesPython() throws {
        let network = EyeNetwork(weights: try EyeNetWeights(contentsOf: Self.weightsURL))
        let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: Self.referenceURL))

        var compared = 0, worst = 0.0, wrongLabel = 0
        for reference in references {
            guard let picture = PNGFile.read(Fixture.dataHome.appendingPathComponent(reference.file)),
                  let buffer = EyeCropper.buffer(from: picture) else { continue }
            let answer = try network.closedProbability(of: buffer)
            compared += 1
            worst = max(worst, abs(answer - reference.closed))
            if (answer > 0.5) != (reference.label == "closed") { wrongLabel += 1 }
        }
        #expect(compared >= 10, "only \(compared) reference pictures were found")
        #expect(worst < 0.001, "largest difference \(worst)")
        #expect(wrongLabel == 0)
    }

    @Test("A picture of the wrong size is refused, not silently resized",
          .enabled(if: available, "no trained model on this machine"))
    func wrongSize() throws {
        let classifier = try EyeClassifier(compiledModel: Self.modelURL)
        #expect(throws: EyeClassifier.ClassifierError.self) {
            try classifier.closedProbability(of: Fixture.frame(width: 128, height: 128))
        }
    }

    @Test("A folder that is not the eye model is refused")
    func notAModel() {
        #expect(throws: (any Error).self) {
            try EyeClassifier(compiledModel: Fixture.temporaryFolder())
        }
    }
}
