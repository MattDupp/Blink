// PROBE: can a weight tensor of an updatable Core ML model be read, and replaced when the
// model is loaded, through the public API (MLParameterKey.weights scoped to a layer)?
import CoreML
import Foundation

let template = URL(fileURLWithPath: CommandLine.arguments[1])

func answer(_ model: MLModel) throws -> Float {
    let picture = try MLMultiArray(shape: [1, 64, 64], dataType: .float32)
    for i in 0..<4096 { picture[i] = NSNumber(value: Float((i * 37) % 101) / 100) }
    let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["eye": picture]))
    return output.featureValue(for: "probabilities")!.multiArrayValue![1].floatValue
}

let plain = MLModelConfiguration()
plain.computeUnits = .cpuOnly
let model = try MLModel(contentsOf: template, configuration: plain)
print("answer of the template:", try answer(model))

let key = MLParameterKey.weights.scoped(to: "linear")
do {
    let value = try model.parameterValue(for: key)
    if let weights = value as? MLMultiArray {
        print("read linear weights: shape \(weights.shape), first \(weights[0])")
        // Replace them by their opposite and load again: does the answer change?
        let flipped = try MLMultiArray(shape: weights.shape, dataType: weights.dataType)
        for i in 0..<weights.count { flipped[i] = NSNumber(value: -weights[i].floatValue) }
        let changed = MLModelConfiguration()
        changed.computeUnits = .cpuOnly
        changed.parameters = [key: flipped]
        do {
            let again = try MLModel(contentsOf: template, configuration: changed)
            print("answer with the linear weights replaced at load:", try answer(again))
            let back = try again.parameterValue(for: key) as? MLMultiArray
            print("weights read back from that model: first \(back?[0] ?? -999) (asked for \(flipped[0]))")
        } catch { print("loading with replaced weights failed: \(error)") }
    } else { print("parameterValue returned \(type(of: value))") }
} catch { print("reading the weights failed: \(error)") }
