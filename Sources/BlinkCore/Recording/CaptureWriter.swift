import Foundation
import CoreGraphics

/// Records what the live pipeline saw, frame by frame, so it can be studied afterwards:
///
///     <root>/<capture>/frames/f000123_L.png      EVERY frame's eye pictures
///     <root>/<capture>/trace.csv                 one line per frame
///
/// WHY. The training pictures are eyes held open or held closed. A real blink is neither:
/// the lid is caught half-way, blurred by its own speed, for 3 to 5 frames in all. To know
/// what the model answers on those frames - and to teach it the right answer - we need to
/// see them. Unlike the recorder, this keeps all 30 frames a second: here the frames in
/// between are exactly what we are after.
public final class CaptureWriter {

    public let folder: URL
    private let trace: FileHandle
    public private(set) var frames = 0

    public static let header = "frame,time,p_left,p_right,p_mean,open_left,open_right,state,event,tick"

    public init(root: URL, name: String) throws {
        folder = root.appendingPathComponent(name, isDirectory: true)
        try PrivateFolder.create(at: folder.appendingPathComponent("frames", isDirectory: true))
        let traceURL = folder.appendingPathComponent("trace.csv")
        try (Self.header + "\n").write(to: traceURL, atomically: true, encoding: .utf8)
        trace = try FileHandle(forWritingTo: traceURL)
        try trace.seekToEnd()
    }

    /// `tick`: a cue sound was played just before this frame ("blink now").
    public func write(frame: Int, time: Double, reading: FrameReading,
                      state: BlinkDetector.State, event: BlinkDetector.Event?, tick: Bool) {
        var bySide: [EyeRegion.Side: EyeReading] = [:]
        for eye in reading.eyes {
            bySide[eye.side] = eye
            if let image = EyeCropper.image(from: eye.picture) {
                let name = String(format: "frames/f%06d_%@.png", frame, eye.side.rawValue)
                PNGFile.write(image, to: folder.appendingPathComponent(name))
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
            number(bySide[.imageLeft]?.closed), number(bySide[.imageRight]?.closed), number(reading.closed),
            number(bySide[.imageLeft]?.openness), number(bySide[.imageRight]?.openness),
            stateName, eventName, tick ? "1" : "",
        ]
        do {
            try trace.write(contentsOf: Data((fields.joined(separator: ",") + "\n").utf8))
            frames += 1
        } catch {
            Log.storage.error("Capture line not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
