import Foundation

/// A training that says nothing for a while is still working, not finished: the page
/// then says so instead of a frozen "About 6 s left".
public enum TrainingSilence {
    public static let seconds = 10.0
    public static func isSilent(lastWord: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastWord) >= seconds
    }
}

/// What a training says while it runs. Each value is one line of text when the training
/// runs in a helper process (`TrainingRun.helper`), read back by the app.
public enum TrainingProgress: Codable, Equatable {
    /// Reading the pictures from disk.
    case reading(done: Int, total: Int)
    /// Checking each pose before learning from it (`PoseCheck`): passes made by the
    /// models that judge them, of all they will make.
    case checkingPoses(done: Int, of: Int)
    /// Poses read the other way without doubt: nothing was learned, the person is asked
    /// to record them again or to leave them out.
    case flagged([PoseFlag])
    /// A pass over every picture has ended. `seconds`: since learning began.
    case learning(pass: Int, of: Int, loss: Float, seconds: Double)
    /// Learning is over: the model that will run is compared with the one that learned.
    case checking
    case finished(ModelInfo)
    case failed(String)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// One line of text (JSON), without the line break.
    public var line: String {
        (try? Self.encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public init?(line: String) {
        guard let data = line.data(using: .utf8), let value = try? Self.decoder.decode(Self.self, from: data) else { return nil }
        self = value
    }
}

/// One whole training, from the sessions on disk to a model ready to install:
///
///     read the pictures -> check the poses -> learn (30 passes) -> check -> write eyenet.weights + model.json
///
/// THE POSES are checked first (`PoseCheck`): a pose held the wrong way stops the training
/// before anything is learned from it, and the person is asked what to do.
///
/// THE CHECK is this route's version of what training/convert.py does for the Python
/// route. The network exists twice: `EyeTrainer` learns on the graphics processor, and
/// `EyeNetwork` answers on the processor, from weights with the normalisation folded in.
/// A mistake in that translation would not crash: the model would simply answer worse.
/// So every picture is given to both, and a model whose two forms differ is not written.
public enum TrainingRun {

    /// Passes over the pictures, as in training/learning.py.
    public static let passes = 30
    /// The two forms of the model must agree to this, on every picture (convert.py's limit).
    public static let largestDifferenceAllowed: Float = 0.001
    /// Fewer pictures than this of either kind cannot teach anything.
    static let fewestPicturesOfAKind = 60
    /// A model that cannot even tell apart the pictures it learned from has not learned.
    static let fewestRightOnOwnPictures = 0.9

    /// Trains on the sessions under `root` and writes the model into `folder`.
    /// Returns what was written, or nil after reporting `.failed` or `.flagged`.
    @discardableResult
    public static func run(sessions root: URL, into folder: URL, seed: UInt64 = 20_261_121, passes: Int = TrainingRun.passes,
                           report: @escaping (TrainingProgress) -> Void) -> ModelInfo? {
        func fail(_ reason: String) -> ModelInfo? {
            report(.failed(reason))
            return nil
        }

        let entries = TrainingSet.list(root: root)
        report(.reading(done: 0, total: entries.count))
        let set = TrainingSet.load(entries) { report(.reading(done: $0, total: entries.count)) }
        // A few pictures gone is a file deleted by hand. Many is something wrong with the
        // disk or the machine, and a model trained on what is left would say nothing of it.
        guard set.count * 50 >= entries.count * 49 else {
            return fail("\(entries.count - set.count) of the \(entries.count) recorded pictures could not be read.")
        }
        let closed = set.closedCount, open = set.count - closed
        guard open >= fewestPicturesOfAKind, closed >= fewestPicturesOfAKind else {
            return fail("There are too few pictures to learn from: \(open) with the eyes open and \(closed) with the eyes closed. "
                        + "Record your eyes first.")
        }
        guard EyeTrainer.isAvailable else {
            return fail("This Mac has no graphics processor that training can use: it needs a Mac with an Apple chip.")
        }
        let flagged = PoseCheck.run(set: set, root: root, seed: seed, passes: passes, report: report)
        guard flagged.isEmpty else {
            report(.flagged(flagged))
            return nil
        }
        guard let trainer = EyeTrainer(seed: seed) else {
            return fail("This Mac has no graphics processor that training can use: it needs a Mac with an Apple chip.")
        }

        let labels = set.labels
        let began = StageTimings.now()
        let losses = set.gray.withUnsafeBufferPointer { pictures in
            trainer.train(images: pictures.baseAddress!, labels: labels, epochs: passes, seed: seed) { pass, loss in
                report(.learning(pass: pass, of: passes, loss: loss, seconds: StageTimings.now() - began))
            }
        }
        let seconds = StageTimings.now() - began
        guard let lastLoss = losses.last, losses.allSatisfy(\.isFinite) else {
            return fail("The training went wrong: its numbers stopped making sense.")
        }

        report(.checking)
        let learned = set.gray.withUnsafeBufferPointer { trainer.predict(images: $0.baseAddress!, count: set.count) }
        let right = zip(learned, labels).filter { ($0 > 0.5) == ($1 > 0.5) }.count
        guard Double(right) >= fewestRightOnOwnPictures * Double(set.count) else {
            return fail("The model did not learn to tell your open eyes from your closed ones: shown its own \(set.count) pictures "
                        + "again, it called \(right) right. Recording again, with more light on your face, should help.")
        }
        let weights: EyeNetWeights
        do {
            weights = try trainer.weights()
        } catch {
            return fail("The training went wrong: \(error)")
        }
        let network = EyeNetwork(weights: weights)
        var largest: Float = 0
        set.gray.withUnsafeBufferPointer { pictures in
            for index in 0..<set.count {
                let answer = Float(network.closedProbability(ofGray: pictures.baseAddress! + index * EyeNetwork.pixels))
                largest = max(largest, abs(answer - learned[index]))
            }
        }
        guard largest <= largestDifferenceAllowed else {
            return fail("The model that would run does not give the answers of the model that learned "
                        + "(largest difference \(largest)). It was not installed.")
        }

        let info = ModelInfo(trainedOn: Date(), sessions: set.sessions, openPictures: open, closedPictures: closed,
                             passes: passes, seconds: seconds, lastLoss: lastLoss, rightOnOwnPictures: right,
                             largestDifference: largest)
        do {
            try PrivateFolder.create(at: folder)
            try weights.write(to: folder.appendingPathComponent(ModelStore.weightsName))
            try info.write(to: folder.appendingPathComponent(ModelStore.infoName))
        } catch {
            return fail("The model could not be written to disk: \(error.localizedDescription)")
        }
        report(.finished(info))
        return info
    }

    // MARK: - As a helper process

    /// The same, for a process started only to train:
    ///
    ///     BlinkMonitor --train --sessions-dir=<folder> --model-out=<folder>
    ///
    /// WHY ANOTHER PROCESS. The training runs inside Apple's graphics frameworks. One run
    /// of the spike ended there with an assertion (see `EyeTrainer.run`), and an assertion
    /// ends the whole process. In a helper, that is a training to start again; in the app
    /// it would be the app gone, with its window. Each progress value is one line on the
    /// standard output. Returns the exit code.
    public static func helper() -> Int32 {
        guard let sessions = LaunchArguments.folder("sessions-dir"), let out = LaunchArguments.folder("model-out") else {
            print(TrainingProgress.failed("The trainer was started without --sessions-dir and --model-out.").line)
            return 2
        }
        setvbuf(stdout, nil, _IOLBF, 0)        // every line leaves at once
        let passes = LaunchArguments.value(of: "passes").flatMap(Int.init) ?? TrainingRun.passes
        let info = run(sessions: sessions, into: out, passes: passes) { print($0.line) }
        return info == nil ? 1 : 0
    }
}
