import Foundation
import CoreVideo

/// Runs a recorded capture through the pipeline again, from its whole frames:
///
///     stored frame -> EyeReader (find eyes, crop, model) -> BlinkDetector -> one trace line
///
/// the very stages, in the very order, of the app's camera thread (`MonitorPipeline`).
///
/// WHY. Finding the eyes is most of what the app costs, so it is the stage worth changing,
/// and the one stage whose changes could not be judged: move the squares by a few pixels
/// and the model is shown other pictures. Does it still count the same blinks? Nothing
/// recorded could say. A capture that kept its whole frames can: it is replayed through
/// the changed stage, and the count is compared with the blinks a person marked.
///
/// The eye finding under test is handed in (`reader`): the tool that calls this decides
/// which one, and the code that runs is the code the app would run.
public enum CaptureReplay {

    /// What one run answered.
    public struct Outcome {
        /// One line per stored frame, as trace.csv has them.
        public var lines: [TraceLine] = []
        /// What the stages cost, averaged over the run.
        public var timings: StageTimings.Summary?
    }

    /// - `everyFrame`: search for the eyes on every frame, as the app does while it
    ///   records a capture. Otherwise the reader's own schedule decides, as in normal use.
    /// - `atCameraPace`: hand the frames over when the camera did, on a background
    ///   queue, instead of as fast as they can be read. Slower, and the only way to get
    ///   costs that mean something: a stage that runs 30 times a second with pauses in
    ///   between does not cost what it costs flat out (MEASURED 2026-11-20 on Apple
    ///   Vision alone: 5 ms a call flat out, 10 ms at the camera's pace).
    /// - `trace`: every line is also written there, in the format of trace.csv.
    public static func run(_ frames: WholeFrameReader, reader: EyeReader, everyFrame: Bool = false,
                           atCameraPace: Bool = false, trace: CSVAppender? = nil) throws -> Outcome {
        guard atCameraPace else {
            return try play(frames, reader: reader, everyFrame: everyFrame, paced: false, trace: trace)
        }
        // The camera's frames arrive on a queue of "utility" priority (`CameraCapture`);
        // so do these.
        var result: Result<Outcome, Error>?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "blink.replay.frames", qos: .utility).async {
            result = Result { try play(frames, reader: reader, everyFrame: everyFrame, paced: true, trace: trace) }
            done.signal()
        }
        done.wait()
        return try result!.get()
    }

    private static func play(_ frames: WholeFrameReader, reader: EyeReader, everyFrame: Bool,
                             paced: Bool, trace: CSVAppender?) throws -> Outcome {
        var outcome = Outcome()
        var detector = BlinkDetector()
        var timings = StageTimings()
        var started: (clock: Double, camera: Double)?

        while true {
            // A pool per frame, as for the camera's frames: the pictures are freed at once.
            let more: Bool = try autoreleasepool {
                guard let frame = try frames.next() else { return false }
                if paced {
                    let start = started ?? (StageTimings.now(), frame.time)
                    started = start
                    let due = start.clock + (frame.time - start.camera)
                    let wait = due - StageTimings.now()
                    if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
                }
                timings.frameDelivered(at: StageTimings.now())

                // A frame the schedule skips says nothing about the eyes (`MonitorPipeline`).
                var reading = FrameReading()
                if let read = try reader.read(frame.pixels, everyFrame: everyFrame) {
                    reading = read.reading
                    timings.record(read.cost)
                }
                let event = detector.update(time: frame.time, closed: reading.closed)

                var bySide: [EyeRegion.Side: Double] = [:]
                for eye in reading.eyes { bySide[eye.side] = eye.closed }
                var counted = false
                if case .blink = event { counted = true }
                outcome.lines.append(TraceLine(frame: frame.number, time: frame.time, left: bySide[.imageLeft],
                                               right: bySide[.imageRight], mean: reading.closed, blink: counted))
                trace?.append(CaptureWriter.fields(frame: frame.number, time: frame.time, reading: reading,
                                                   state: detector.state, event: event, tick: false))
                return true
            }
            if !more { break }
        }
        outcome.timings = timings.takeSummary(at: StageTimings.now())
        return outcome
    }

    // MARK: - Two runs compared

    /// The blinks two runs counted, paired up: a blink counted by both lands on the same
    /// frame, or a frame or two apart when the squares were a frame old.
    public struct SameBlinks: Equatable {
        public var both = 0
        /// Frames at which only the first run counted a blink, and only the second.
        public var onlyFirst: [Int] = []
        public var onlySecond: [Int] = []

        public var same: Bool { onlyFirst.isEmpty && onlySecond.isEmpty }
    }

    /// Pairs the blinks of two runs that are at most `within` frames apart.
    ///
    /// This asks nothing of the marks: it says whether a change to the eye finding counts
    /// the blinks the reference counts, on every frame - also those with one eye hidden,
    /// which the marks do not cover (`RecordedCapture.score`).
    public static func sameBlinks(_ first: [TraceLine], _ second: [TraceLine], within: Int = 3) -> SameBlinks {
        var result = SameBlinks()
        var others = RecordedCapture.counted(in: second)
        for frame in RecordedCapture.counted(in: first) {
            if let match = others.firstIndex(where: { abs($0 - frame) <= within }) {
                others.remove(at: match)
                result.both += 1
            } else {
                result.onlyFirst.append(frame)
            }
        }
        result.onlySecond = others
        return result
    }

    /// How far the answers of one run are from another's, frame by frame.
    public struct Difference: Equatable {
        /// Frames both runs answered.
        public var compared = 0
        /// Frames only one of the two answered (the other did not read the eyes).
        public var readByOneOnly = 0
        public var meanGap = 0.0
        public var largestGap = 0.0
        /// Frames whose answers are on different sides of 50%.
        public var otherSide = 0
    }

    public static func difference(_ a: [TraceLine], _ b: [TraceLine]) -> Difference {
        var result = Difference()
        let other = Dictionary(b.map { ($0.frame, $0) }, uniquingKeysWith: { first, _ in first })
        var sum = 0.0
        for line in a {
            guard let match = other[line.frame] else { continue }
            switch (line.mean, match.mean) {
            case (let x?, let y?):
                result.compared += 1
                sum += abs(x - y)
                result.largestGap = max(result.largestGap, abs(x - y))
                if (x > 0.5) != (y > 0.5) { result.otherSide += 1 }
            case (nil, nil):
                break
            default:
                result.readByOneOnly += 1
            }
        }
        result.meanGap = result.compared > 0 ? sum / Double(result.compared) : 0
        return result
    }
}
