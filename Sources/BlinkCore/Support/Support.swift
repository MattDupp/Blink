import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

/// Where the apps write their diagnostic messages. Read them with Console.app, or:
///
///     log stream --predicate 'subsystem == "local.blinkmonitor"'
public enum Log {
    private static let subsystem = "local.blinkmonitor"
    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let app = Logger(subsystem: subsystem, category: "app")
}

/// Folders that hold recordings.
public enum PrivateFolder {

    /// Creates the folder (and any missing parent) readable by its owner only.
    ///
    /// Recordings are pictures of someone's eyes. A folder made the usual way can be read
    /// by every account of the Mac; these cannot.
    public static func create(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

/// Writes pictures to disk as PNG.
///
/// PNG, not JPEG: PNG keeps every pixel exactly. JPEG throws detail away, and its blocks
/// are plainly visible on a 64x64 picture - a model would learn from them.
public enum PNGFile {

    /// Returns false (and logs why) when the picture could not be written.
    @discardableResult
    public static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            Log.storage.error("PNG not created: \(url.lastPathComponent, privacy: .public)")
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            Log.storage.error("PNG not written: \(url.lastPathComponent, privacy: .public)")
            return false
        }
        return true
    }

    public static func read(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// How long each stage of the pipeline takes, averaged over a stretch of frames.
///
/// "It feels slow" cannot be optimised; "finding the eyes takes 2.1 ms of a 2.9 ms frame"
/// can. The pipeline times its own stages, and every change to it is judged on these
/// numbers.
public struct StageTimings {

    /// Averages over the frames since the previous summary, in milliseconds.
    public struct Summary: Equatable {
        public var findEyes = 0.0
        public var crop = 0.0
        public var model = 0.0
        /// The whole frame, including the bookkeeping around the three stages.
        public var total = 0.0
        public var worstTotal = 0.0
        /// Frames delivered by the camera, per second.
        public var framesPerSecond = 0.0
        /// Share of those frames that were analysed (the rest were skipped: no face in view).
        public var analysedShare = 1.0

        public init() {}
    }

    private var findEyes = 0.0, crop = 0.0, model = 0.0, total = 0.0, worst = 0.0
    private var analysed = 0
    private var delivered = 0
    private var since: Double?

    public init() {}

    /// The time now, in seconds, from a clock that never jumps (not the wall clock).
    public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// One analysed frame; durations in seconds.
    public mutating func record(findEyes: Double, crop: Double, model: Double, total: Double) {
        self.findEyes += findEyes
        self.crop += crop
        self.model += model
        self.total += total
        worst = max(worst, total)
        analysed += 1
    }

    /// Every frame the camera delivered, analysed or skipped.
    public mutating func frameDelivered(at time: Double) {
        if since == nil { since = time }
        delivered += 1
    }

    /// The averages since the last call, then starts a new stretch. Nil before any frame.
    public mutating func takeSummary(at time: Double) -> Summary? {
        guard let since, delivered > 0, time > since else { return nil }
        var summary = Summary()
        let frames = Double(max(analysed, 1))
        summary.findEyes = findEyes / frames * 1000
        summary.crop = crop / frames * 1000
        summary.model = model / frames * 1000
        summary.total = total / frames * 1000
        summary.worstTotal = worst * 1000
        summary.framesPerSecond = Double(delivered) / (time - since)
        summary.analysedShare = Double(analysed) / Double(delivered)
        self = StageTimings()
        self.since = time
        return summary
    }
}
