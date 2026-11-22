import Foundation
import BlinkCore

/// Which model reads the eyes, and where it came from.
///
/// There can be several on one Mac, and the order below decides:
///
///   1. `--model=<EyeNet.mlmodelc>`: named at launch, by someone comparing models.
///   2. The model trained in this app, once its setup is finished.
///   3. A model built into the app by `make monitor` (the Python route).
///   4. None: the app opens its setup.
///
/// Why 2 before 3: a model you trained in the app is the one you last chose. A developer
/// who wants the built-in one back deletes the other in Settings, or names one at launch.
enum ModelSource: Equatable {
    case given(URL)
    case trainedHere(ModelInfo)
    case builtIn(URL)
    case none

    /// The model `make monitor` copies into the app, when it found one to copy:
    /// BlinkMonitor.app/Contents/Resources/EyeNet.mlmodelc.
    static var builtInModel: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("EyeNet.mlmodelc", isDirectory: true)
    }

    static func resolve(store: ModelStore, given: URL? = LaunchArguments.folder("model"),
                        builtIn: URL = ModelSource.builtInModel) -> ModelSource {
        if let given { return .given(given) }
        if let info = store.info(), info.isAccepted { return .trainedHere(info) }
        if FileManager.default.fileExists(atPath: builtIn.path) { return .builtIn(builtIn) }
        return .none
    }

    /// The model itself, ready to answer; nil when there is none.
    func judge(store: ModelStore) throws -> EyeJudging? {
        switch self {
        case .given(let url), .builtIn(let url): return try EyeClassifier(compiledModel: url)
        case .trainedHere: return try store.network()
        case .none: return nil
        }
    }

    /// Where a model that failed to load was looked for, and how to make it again.
    /// For the log only (a developer reads it): the panel says `StartFailure.sentence`.
    var remedy: String {
        switch self {
        case .given(let url): return "It was named at launch: \(url.path)"
        case .builtIn(let url): return "It is the one built into the app: \(url.path)\nMake it again with: make train, then make monitor"
        case .trainedHere: return "It is the one trained in this app. Settings > Your Model can delete it; setup then trains another."
        case .none: return ""
        }
    }
}
