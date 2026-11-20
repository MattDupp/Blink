import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BlinkCore

/// One eye of one captured frame.
struct CapturedEye {
    let side: EyeRegion.Side
    let picture: CGImage
    /// The model's answer for this picture.
    let closed: Double
    /// Vision's outline height / width (EyeRegion.openness).
    let openness: Double
}

/// Records what the live pipeline saw, frame by frame, so it can be studied afterwards:
///
///     data/live/<capture>/frames/f000123_L.png      EVERY frame's eye pictures
///     data/live/<capture>/trace.csv                 one line per frame
///
/// WHY. The training pictures are eyes held open or held closed. A real blink is neither:
/// the lid is caught half-way, blurred by its own speed, for 3 to 5 frames in all. To know
/// what the model answers on those frames - and to teach it the right answer - we need to
/// see them. Unlike the recorder, this keeps all 30 frames a second: here the frames in
/// between are exactly what we are after.
final class CaptureWriter {

    let folder: URL
    private let trace: FileHandle
    private(set) var frames = 0

    static let header = "frame,time,p_left,p_right,p_mean,open_left,open_right,state,event,tick"

    init(root: URL, name: String) throws {
        folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames", isDirectory: true),
                                                withIntermediateDirectories: true)
        let traceURL = folder.appendingPathComponent("trace.csv")
        try (Self.header + "\n").write(to: traceURL, atomically: true, encoding: .utf8)
        trace = try FileHandle(forWritingTo: traceURL)
        try trace.seekToEnd()
    }

    /// `tick`: a cue sound was played just before this frame ("blink now").
    func write(frame: Int, time: Double, eyes: [CapturedEye], mean: Double?,
               state: BlinkDetector.State, event: BlinkDetector.Event?, tick: Bool) {
        var byside: [EyeRegion.Side: CapturedEye] = [:]
        for eye in eyes {
            byside[eye.side] = eye
            let url = folder.appendingPathComponent(String(format: "frames/f%06d_%@.png", frame, eye.side.rawValue))
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, eye.picture, nil)
                CGImageDestinationFinalize(destination)
            }
        }

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
        let fields = [
            String(frame), String(format: "%.4f", time),
            number(byside[.imageLeft]?.closed), number(byside[.imageRight]?.closed), number(mean),
            number(byside[.imageLeft]?.openness), number(byside[.imageRight]?.openness),
            stateName, eventName, tick ? "1" : "",
        ]
        if let line = (fields.joined(separator: ",") + "\n").data(using: .utf8) {
            try? trace.write(contentsOf: line)
        }
        frames += 1
    }
}
