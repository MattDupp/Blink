import AVFoundation
import CoreVideo
import Foundation

// The whole camera picture of every frame of a capture, kept as a movie:
//
//     <capture>/whole-frames.mov     the frames
//     <capture>/whole-frames.csv     one line per frame of the movie, in order: its number and time
//     <capture>/whole-frames.json    how the camera described its colours
//
// WHY. An ordinary capture keeps the two 64x64 eye pictures of each frame: what the model
// was shown. That is enough to judge the MODEL again, and useless to judge the stage before
// it: change how the eyes are found and the squares move, the pictures change, and no
// stored picture says what the model would have answered. With the whole frames, a capture
// can be run again through any way of finding the eyes (see `CaptureReplay`).
//
// WHAT IS KEPT IS A FACE. These files never leave the Mac: they are written to a folder
// only its owner can read, under data/, which git ignores.

/// The names of a capture's whole-frame files.
public enum WholeFrameFiles {
    public static func movie(in folder: URL) -> URL { folder.appendingPathComponent("whole-frames.mov") }
    public static func index(in folder: URL) -> URL { folder.appendingPathComponent("whole-frames.csv") }
    public static func colours(in folder: URL) -> URL { folder.appendingPathComponent("whole-frames.json") }

    public static let indexHeader = "frame,time"

    /// The three labels a pixel buffer carries about its colours. Core Image reads them
    /// when it cuts the eye pictures, so a frame read back must carry the camera's own.
    static let colourKeys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                             kCVImageBufferYCbCrMatrixKey]
}

/// Writes the frames of one capture to a movie, as they come from the camera.
///
/// THE FORMAT (see `Format`) is a trade: exact pixels would take 15 GB a minute. Apple
/// ProRes 422 stores each frame on its own (no frame is described as "the previous one,
/// slightly changed"), keeps the full detail of the picture, and takes about 1 GB a minute.
/// What it costs the measurement is itself measured: `CaptureReplay` compares the answers
/// replayed from the movie with the ones the app recorded from the camera.
public final class WholeFrameWriter: @unchecked Sendable {

    public enum Format {
        /// Each frame stored on its own, visually lossless: about 1 GB a minute at 1920x1080.
        case proRes422
        /// A quarter of the size, each frame still stored on its own; the picture is rounded more.
        case hevc(megabitsPerSecond: Double)

        var settings: [String: Any] {
            switch self {
            case .proRes422:
                return [AVVideoCodecKey: AVVideoCodecType.proRes422]
            case .hevc(let megabits):
                return [AVVideoCodecKey: AVVideoCodecType.hevc,
                        AVVideoCompressionPropertiesKey: [
                            AVVideoAverageBitRateKey: Int(megabits * 1_000_000),
                            AVVideoMaxKeyFrameIntervalKey: 1,        // every frame on its own
                            AVVideoAllowFrameReorderingKey: false,
                            AVVideoExpectedSourceFrameRateKey: 30,
                        ] as [String: Any]]
            }
        }
    }

    public enum WriterError: Error, CustomStringConvertible {
        case notStarted(String)

        public var description: String {
            switch self {
            case .notStarted(let why): return "The movie of whole frames could not be started: \(why)."
            }
        }
    }

    /// Frames stored so far.
    public var frames: Int { state.withLock { $0.frames } }

    private struct State {
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var index: CSVAppender?
        var frames = 0
        var finished = false
        var failed = false
    }

    private let folder: URL
    private let format: Format
    /// How long a frame may wait for the encoder before it is given up (seconds).
    private let patience: Double
    private let state = Locked(State())

    /// `folder`: the capture's folder; it must exist.
    public init(folder: URL, format: Format = .proRes422, patience: Double = 0.02) {
        self.folder = folder
        self.format = format
        self.patience = patience
    }

    /// Stores one frame. Returns false when it could not be stored (the encoder was still
    /// busy, or the movie failed): the frame is then absent from the index too, so what
    /// the index lists is exactly what the movie holds.
    @discardableResult
    public func append(_ pixelBuffer: CVPixelBuffer, frame: Int, time: Double) -> Bool {
        state.withLock { state -> Bool in
            guard !state.finished, !state.failed else { return false }
            do {
                if state.writer == nil { try start(&state, with: pixelBuffer, at: time) }
            } catch {
                state.failed = true
                Log.storage.error("Whole frames not kept: \(String(describing: error), privacy: .public)")
                return false
            }
            guard let input = state.input, let adaptor = state.adaptor, let index = state.index else { return false }

            // The encoder works on its own threads and is far quicker than the camera, but
            // it may not have finished with the previous frame at the very moment the next
            // one arrives. Waiting a few milliseconds costs nothing; waiting for long would
            // make the camera drop frames, which is worse than this movie missing one.
            let deadline = StageTimings.now() + patience
            while !input.isReadyForMoreMediaData && StageTimings.now() < deadline { usleep(500) }
            guard input.isReadyForMoreMediaData,
                  adaptor.append(pixelBuffer, withPresentationTime: Self.clock(time)) else { return false }
            guard index.append([String(frame), String(format: "%.4f", time)]) else {
                state.failed = true      // a frame in the movie that the index does not list
                return false
            }
            state.frames += 1
            return true
        }
    }

    /// Closes the movie. Frames given afterwards are refused. `completion` is called
    /// (on any thread) once the file is whole, with whether it is usable.
    public func finish(_ completion: @escaping @Sendable (Bool) -> Void) {
        let writer: AVAssetWriter? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            state.input?.markAsFinished()
            state.index = nil           // closes the index file
            return state.failed ? nil : state.writer
        }
        guard let writer else {
            completion(false)
            return
        }
        writer.finishWriting {
            completion(writer.status == .completed)
        }
    }

    /// The same, for code that can wait.
    public func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            finish { continuation.resume(returning: $0) }
        }
    }

    // MARK: -

    /// The camera's seconds as a movie time (microseconds).
    static func clock(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * 1_000_000).rounded()), timescale: 1_000_000)
    }

    /// Opens the movie on the first frame: only then are the picture's size and the
    /// camera's colour labels known.
    private func start(_ state: inout State, with pixelBuffer: CVPixelBuffer, at time: Double) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let movie = WholeFrameFiles.movie(in: folder)
        try? FileManager.default.removeItem(at: movie)

        var settings = format.settings
        settings[AVVideoWidthKey] = width
        settings[AVVideoHeightKey] = height
        // No colour settings on purpose: the movie is then labelled as the camera labels
        // its frames, and their values are stored without being converted to other colours.
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw WriterError.notStarted("this Mac cannot write the format")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(pixelBuffer),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw WriterError.notStarted("the picture was refused") }
        writer.add(input)
        guard writer.startWriting() else {
            throw WriterError.notStarted(writer.error?.localizedDescription ?? "unknown reason")
        }
        writer.startSession(atSourceTime: Self.clock(time))

        try? FileManager.default.removeItem(at: WholeFrameFiles.index(in: folder))
        state.index = try CSVAppender(url: WholeFrameFiles.index(in: folder), header: WholeFrameFiles.indexHeader)
        try WholeFrameColours(of: pixelBuffer, width: width, height: height)
            .write(to: WholeFrameFiles.colours(in: folder))
        state.writer = writer
        state.input = input
        state.adaptor = adaptor
    }
}

/// How the camera described the colours of its frames, and their size.
struct WholeFrameColours: Codable, Equatable {
    var width: Int
    var height: Int
    /// The labels the camera's frames carried, by name ("CVImageBufferTransferFunction": ...).
    /// A label that was absent is absent here.
    var labels: [String: String]

    init(of pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        self.width = width
        self.height = height
        labels = [:]
        for key in WholeFrameFiles.colourKeys {
            if let value = CVBufferCopyAttachment(pixelBuffer, key, nil) as? String {
                labels[key as String] = value
            }
        }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }

    /// Gives a frame read back from the movie the labels the camera's frames carried.
    func apply(to pixelBuffer: CVPixelBuffer) {
        for key in WholeFrameFiles.colourKeys {
            if let value = labels[key as String] {
                CVBufferSetAttachment(pixelBuffer, key, value as CFString, .shouldPropagate)
            } else {
                CVBufferRemoveAttachment(pixelBuffer, key)
            }
        }
    }
}

/// Reads the frames of a capture back, in order.
public final class WholeFrameReader {

    public struct Frame {
        /// The app's frame number: the one in trace.csv and in the names of the eye pictures.
        public let number: Int
        /// Seconds, on the camera's clock.
        public let time: Double
        public let pixels: CVPixelBuffer
    }

    public enum ReaderError: Error, CustomStringConvertible {
        case noFrames(URL)
        case unreadable(String)
        /// The movie and its index do not tell the same story.
        case outOfStep(String)

        public var description: String {
            switch self {
            case .noFrames(let folder): return "\(folder.lastPathComponent) keeps no whole frames (no whole-frames.mov)."
            case .unreadable(let why): return "The movie of whole frames cannot be read: \(why)."
            case .outOfStep(let what): return "The movie of whole frames and its index disagree: \(what)."
            }
        }
    }

    /// Frames the movie holds.
    public var count: Int { index.count }
    /// Their numbers, in order.
    public var numbers: [Int] { index.map(\.number) }
    public let frameSize: CGSize

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let index: [(number: Int, time: Double)]
    private let colours: WholeFrameColours?
    private var position = 0

    /// True when `folder` is a capture that kept its whole frames.
    public static func hasFrames(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: WholeFrameFiles.movie(in: folder).path)
            && FileManager.default.fileExists(atPath: WholeFrameFiles.index(in: folder).path)
    }

    public init(folder: URL) async throws {
        guard Self.hasFrames(folder) else { throw ReaderError.noFrames(folder) }

        let lines = try String(contentsOf: WholeFrameFiles.index(in: folder), encoding: .utf8)
            .split(separator: "\n").dropFirst()
        index = try lines.map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 2, let number = Int(fields[0]), let time = Double(fields[1]) else {
                throw ReaderError.outOfStep("the index line '\(line)' is not a frame number and a time")
            }
            return (number, time)
        }
        colours = (try? Data(contentsOf: WholeFrameFiles.colours(in: folder)))
            .flatMap { try? JSONDecoder().decode(WholeFrameColours.self, from: $0) }

        let asset = AVURLAsset(url: WholeFrameFiles.movie(in: folder))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReaderError.unreadable("it has no picture")
        }
        frameSize = try await track.load(.naturalSize)
        reader = try AVAssetReader(asset: asset)
        // BGRA, as the camera delivers its frames to the app.
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ReaderError.unreadable("its picture cannot be decoded") }
        reader.add(output)
        guard reader.startReading() else {
            throw ReaderError.unreadable(reader.error?.localizedDescription ?? "unknown reason")
        }
    }

    /// The next frame, or nil after the last one.
    public func next() throws -> Frame? {
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }   // a marker, not a picture
            guard position < index.count else {
                throw ReaderError.outOfStep("the movie holds more frames than the \(index.count) of its index")
            }
            let (number, time) = index[position]
            // The movie's own clock starts at its first frame: each frame must sit where
            // the index says, or frame numbers would be given to the wrong pictures.
            let expected = time - index[0].time
            let found = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard abs(found - expected) < 0.002 else {
                throw ReaderError.outOfStep(String(format: "frame %d is at %.4f s in the movie, %.4f s in the index",
                                                   number, found, expected))
            }
            position += 1
            colours?.apply(to: pixels)
            return Frame(number: number, time: time, pixels: pixels)
        }
        if reader.status == .failed {
            throw ReaderError.unreadable(reader.error?.localizedDescription ?? "unknown reason")
        }
        guard position == index.count else {
            throw ReaderError.outOfStep("the movie holds \(position) frames, its index \(index.count)")
        }
        return nil
    }
}
