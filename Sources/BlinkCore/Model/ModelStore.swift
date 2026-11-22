import Foundation

/// What is known about a model trained in the app: written next to its weights, as
/// model.json, and shown in Settings.
public struct ModelInfo: Codable, Equatable {

    /// The test at the end of setup: ten ticks, a blink at each (`ProofTest`).
    public struct Proof: Codable, Equatable {
        public var found: Int
        public var of: Int
        /// Blinks counted that no tick asked for.
        public var extra: Int
        public var on: Date
        /// You chose to use the model: the test passed, or you said "use it anyway".
        public var accepted: Bool

        public init(found: Int, of: Int, extra: Int, on: Date, accepted: Bool) {
            self.found = found
            self.of = of
            self.extra = extra
            self.on = ModelInfo.wholeSecond(on)
            self.accepted = accepted
        }
    }

    public var trainedOn: Date
    public var sessions: [String]
    public var openPictures: Int
    public var closedPictures: Int
    public var passes: Int
    /// How long the learning took, in seconds.
    public var seconds: Double
    public var lastLoss: Float
    /// Shown its own pictures again, unaltered, how many it called right.
    public var rightOnOwnPictures: Int
    /// The largest difference between the model that learned and the model that runs.
    public var largestDifference: Float
    /// Nil until the test has been taken.
    public var proof: Proof?

    public var pictures: Int { openPictures + closedPictures }

    /// Setup is finished: there is a model, and you chose to use it.
    public var isAccepted: Bool { proof?.accepted ?? false }

    public init(trainedOn: Date, sessions: [String], openPictures: Int, closedPictures: Int, passes: Int, seconds: Double,
                lastLoss: Float, rightOnOwnPictures: Int, largestDifference: Float, proof: Proof? = nil) {
        self.trainedOn = Self.wholeSecond(trainedOn)
        self.sessions = sessions
        self.openPictures = openPictures
        self.closedPictures = closedPictures
        self.passes = passes
        self.seconds = seconds
        self.lastLoss = lastLoss
        self.rightOnOwnPictures = rightOnOwnPictures
        self.largestDifference = largestDifference
        self.proof = proof
    }

    /// Dates are written to the second: kept that way in memory too, what is read back
    /// from the file is equal to what was written.
    static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    public init(contentsOf url: URL) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(ModelInfo.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Where the app keeps the model it trained, and how one replaces another:
///
///     <base>/model/eyenet.weights      the trained numbers (`EyeNetWeights`)
///     <base>/model/model.json          what is known about them (`ModelInfo`)
///     <base>/model.new/                a training writes here first
///     <base>/model.previous/           the model before the last training
///
/// A training never writes over the model in use: it fills `model.new`, and only a model
/// that passed its check is moved into place. The one it replaces is kept once, so that a
/// new session that made things worse can be undone.
public struct ModelStore {

    public static let weightsName = "eyenet.weights"
    public static let infoName = "model.json"

    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// In the app's own folder: ~/Library/Application Support/BlinkMonitor.
    public static var standard: ModelStore { ModelStore(base: HistoryStore.applicationFolder) }

    public var folder: URL { base.appendingPathComponent("model", isDirectory: true) }
    public var staging: URL { base.appendingPathComponent("model.new", isDirectory: true) }
    public var previous: URL { base.appendingPathComponent("model.previous", isDirectory: true) }

    private var files: FileManager { .default }

    /// What is known about the installed model; nil when there is none (or it is unreadable).
    public func info() -> ModelInfo? {
        guard files.fileExists(atPath: folder.appendingPathComponent(Self.weightsName).path) else { return nil }
        return try? ModelInfo(contentsOf: folder.appendingPathComponent(Self.infoName))
    }

    /// The installed model, ready to answer.
    public func network() throws -> EyeNetwork {
        EyeNetwork(weights: try EyeNetWeights(contentsOf: folder.appendingPathComponent(Self.weightsName)))
    }

    public var hasPrevious: Bool {
        files.fileExists(atPath: previous.appendingPathComponent(Self.weightsName).path)
    }

    /// An empty `model.new` for a training to fill.
    public func prepareStaging() throws {
        try? files.removeItem(at: staging)
        try PrivateFolder.create(at: staging)
    }

    public func discardStaging() {
        try? files.removeItem(at: staging)
    }

    /// Moves the model a training left in `model.new` into place. The model it replaces
    /// becomes the previous one.
    public func installStaged() throws {
        // Read it first: a folder that does not hold a whole model must not replace one.
        _ = try EyeNetWeights(contentsOf: staging.appendingPathComponent(Self.weightsName))
        _ = try ModelInfo(contentsOf: staging.appendingPathComponent(Self.infoName))
        if files.fileExists(atPath: folder.path) {
            try? files.removeItem(at: previous)
            try files.moveItem(at: folder, to: previous)
        }
        try files.moveItem(at: staging, to: folder)
    }

    /// Puts the previous model back; the one it replaces is deleted.
    public func restorePrevious() throws {
        guard hasPrevious else { return }
        try? files.removeItem(at: folder)
        try files.moveItem(at: previous, to: folder)
    }

    /// Writes the result of the test next to the model it tested.
    public func setProof(_ proof: ModelInfo.Proof?) throws {
        guard var info = info() else { return }
        info.proof = proof
        try info.write(to: folder.appendingPathComponent(Self.infoName))
    }

    /// Deletes the model, the previous one and anything a training left behind. For good.
    public func delete() throws {
        for folder in [folder, staging, previous] where files.fileExists(atPath: folder.path) {
            try files.removeItem(at: folder)
        }
    }
}
