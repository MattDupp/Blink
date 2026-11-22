import Foundation
import CoreGraphics
import CoreVideo

/// Records what the live pipeline saw, frame by frame, so it can be studied afterwards:
///
///     <root>/<capture>/frames/f000123_L.png      EVERY frame's eye pictures
///     <root>/<capture>/trace.csv                 one line per frame
///     <root>/<capture>/whole-frames.mov ...      the whole camera picture, when asked for
///
/// WHY. The training pictures are eyes held open or held closed. A real blink is neither:
/// the lid is caught half-way, blurred by its own speed, for 3 to 5 frames in all. To know
/// what the model answers on those frames - and to teach it the right answer - we need to
/// see them. Unlike a recorded session, this keeps all 30 frames a second: here the frames in
/// between are exactly what we are after.
///
/// WITH WHOLE FRAMES (`wholeFrames`), the camera's whole picture is kept too, so that the
/// capture can be run again through another way of finding the eyes (`CaptureReplay`).
/// That is a film of a face, where the rest is two small pictures of eyes: it is asked
/// for explicitly, and never the default.
public final class CaptureWriter {

    public let folder: URL
    private let trace: CSVAppender
    private let movie: WholeFrameWriter?
    public private(set) var frames = 0

    public static let header = "frame,time,p_left,p_right,p_mean,open_left,open_right,state,event,tick"

    public init(root: URL, name: String, wholeFrames: Bool = false) throws {
        folder = root.appendingPathComponent(name, isDirectory: true)
        try PrivateFolder.create(at: folder.appendingPathComponent("frames", isDirectory: true))
        trace = try CSVAppender(url: folder.appendingPathComponent("trace.csv"), header: Self.header)
        movie = wholeFrames ? WholeFrameWriter(folder: folder) : nil
    }

    /// True for a capture that keeps the whole camera picture.
    public var keepsWholeFrames: Bool { movie != nil }
    /// Whole frames stored so far.
    public var wholeFrames: Int { movie?.frames ?? 0 }

    /// `tick`: a cue sound was played just before this frame ("blink now").
    /// `pixelBuffer`: the frame itself, kept when the capture keeps whole frames.
    public func write(frame: Int, time: Double, reading: FrameReading,
                      state: BlinkDetector.State, event: BlinkDetector.Event?, tick: Bool,
                      pixelBuffer: CVPixelBuffer? = nil) {
        for eye in reading.eyes {
            if let picture = eye.picture, let image = EyeCropper.image(from: picture) {
                let name = String(format: "frames/f%06d_%@.png", frame, eye.side.rawValue)
                PNGFile.write(image, to: folder.appendingPathComponent(name))
            }
        }
        if let pixelBuffer { movie?.append(pixelBuffer, frame: frame, time: time) }
        let fields = Self.fields(frame: frame, time: time, reading: reading, state: state, event: event, tick: tick)
        if trace.append(fields) { frames += 1 }
    }

    /// Closes the capture's files. Returns once they are whole; false when the whole
    /// frames were asked for and could not be kept.
    public func finish() async -> Bool {
        guard let movie else { return true }
        return await movie.finish()
    }

    /// One line of trace.csv. A replay writes its own traces with it, so that they read
    /// exactly like the app's.
    public static func fields(frame: Int, time: Double, reading: FrameReading,
                              state: BlinkDetector.State, event: BlinkDetector.Event?, tick: Bool) -> [String] {
        var bySide: [EyeRegion.Side: EyeReading] = [:]
        for eye in reading.eyes { bySide[eye.side] = eye }

        func number(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "" }
        let stateName: String
        switch state {
        case .unknown: stateName = "unknown"
        case .open: stateName = "open"
        case .closed: stateName = "closed"
        }
        let eventName: String
        switch event {
        case .blink?: eventName = "blink"
        case .longClosure?: eventName = "long"
        case nil: eventName = ""
        }
        return [
            String(frame), String(format: "%.4f", time),
            number(bySide[.imageLeft]?.closed), number(bySide[.imageRight]?.closed), number(reading.closed),
            number(bySide[.imageLeft]?.openness), number(bySide[.imageRight]?.openness),
            stateName, eventName, tick ? "1" : "",
        ]
    }
}
