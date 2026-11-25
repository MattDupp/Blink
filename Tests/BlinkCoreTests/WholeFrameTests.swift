import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import BlinkCore

/// The whole frames of a capture, written to a movie and read back.
///
/// The frames here are painted in memory and small (640x360), so the tests run anywhere:
/// no camera, no face, no model.
@Suite("Whole frames kept by a capture")
struct WholeFrameTests {

    /// Frame `i` of a made-up capture: the red-and-blue square, further right at each frame.
    static func square(_ i: Int) -> CGRect {
        CGRect(x: 100 + 24 * i, y: 120, width: 96, height: 96)
    }

    /// Writes `count` painted frames numbered from 100, 30 a second from 5 s on the clock.
    static func writeCapture(to folder: URL, count: Int, format: WholeFrameWriter.Format = .proRes422) async throws {
        try PrivateFolder.create(at: folder)
        // A test hands its frames over as fast as it can, where a camera leaves 33 ms
        // between two: it is given the patience to wait for the encoder.
        let writer = WholeFrameWriter(folder: folder, format: format, patience: 5)
        for i in 0..<count {
            let frame = Fixture.frame(width: 640, height: 360, target: square(i))
            #expect(writer.append(frame, frame: 100 + i, time: 5 + Double(i) / 30))
        }
        #expect(writer.frames == count)
        #expect(await writer.finish())
    }

    @Test("Every frame comes back in order, with its number, its time and its picture",
          arguments: [WholeFrameWriter.Format.proRes422, .hevc(megabitsPerSecond: 20)])
    func roundTrip(format: WholeFrameWriter.Format) async throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Self.writeCapture(to: folder, count: 12, format: format)

        #expect(WholeFrameReader.hasFrames(folder))
        let reader = try await WholeFrameReader(folder: folder)
        #expect(reader.count == 12)
        #expect(reader.frameSize == CGSize(width: 640, height: 360))

        var read = 0
        while let frame = try reader.next() {
            #expect(frame.number == 100 + read)
            #expect(abs(frame.time - (5 + Double(read) / 30)) < 0.0001)
            #expect(CVPixelBufferGetWidth(frame.pixels) == 640 && CVPixelBufferGetHeight(frame.pixels) == 360)
            #expect(CVPixelBufferGetPixelFormatType(frame.pixels) == kCVPixelFormatType_32BGRA)

            // The square is where THIS frame painted it, the right way up: a frame given
            // another frame's number, or a picture upside down, shows here.
            let image = try #require(EyeCropper.image(from: frame.pixels))
            let square = Self.square(read)
            let top = Fixture.pixel(of: image, x: Int(square.midX), y: Int(square.minY) + 20)
            let bottom = Fixture.pixel(of: image, x: Int(square.midX), y: Int(square.maxY) - 20)
            let beside = Fixture.pixel(of: image, x: Int(square.minX) - 40, y: Int(square.midY))
            #expect(top.r > 215 && top.b < 40, "frame \(read): the top of the square must be red, got \(top)")
            #expect(bottom.b > 215 && bottom.r < 40, "frame \(read): the bottom must be blue, got \(bottom)")
            #expect(abs(beside.r - 128) <= 3 && abs(beside.g - 128) <= 3 && abs(beside.b - 128) <= 3,
                    "frame \(read): the background must stay grey, got \(beside)")
            read += 1
        }
        #expect(read == 12)
    }

    @Test("The index lists exactly the frames of the movie, and the folder says how the camera labelled its colours")
    func filesOnDisk() async throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Self.writeCapture(to: folder, count: 3)

        let index = try String(contentsOf: WholeFrameFiles.index(in: folder), encoding: .utf8)
        #expect(index == "frame,time\n100,5.0000\n101,5.0333\n102,5.0667\n")
        let colours = try JSONDecoder().decode(WholeFrameColours.self,
                                               from: Data(contentsOf: WholeFrameFiles.colours(in: folder)))
        #expect(colours.width == 640 && colours.height == 360)
    }

    @Test("A frame read back carries the colour labels the camera's frames carried")
    func colourLabels() {
        let camera = Fixture.frame(width: 64, height: 64)
        CVBufferSetAttachment(camera, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let colours = WholeFrameColours(of: camera, width: 64, height: 64)
        #expect(colours.labels == [kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2 as String])

        // Read back, the decoder labelled the frame its own way: the camera's labels win.
        let decoded = Fixture.frame(width: 64, height: 64)
        CVBufferSetAttachment(decoded, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(decoded, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        colours.apply(to: decoded)
        #expect(WholeFrameColours(of: decoded, width: 64, height: 64) == colours)
    }

    @Test("Frames given after the movie is closed are refused, and a folder without a movie has no frames")
    func closedAndMissing() async throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try PrivateFolder.create(at: folder)
        #expect(!WholeFrameReader.hasFrames(folder))
        await #expect(throws: WholeFrameReader.ReaderError.self) { _ = try await WholeFrameReader(folder: folder) }

        let writer = WholeFrameWriter(folder: folder, patience: 5)
        #expect(writer.append(Fixture.frame(width: 640, height: 360), frame: 1, time: 0))
        #expect(await writer.finish())
        #expect(!writer.append(Fixture.frame(width: 640, height: 360), frame: 2, time: 0.0333))
        #expect(writer.frames == 1)
        #expect(try await WholeFrameReader(folder: folder).count == 1)
    }
}

// MARK: - Replaying

/// Stands in for Apple's Vision: the eyes are where the tests paint them. `lost` lists the
/// searches (counted from 0) on which it sees no face.
final class PaintedEyes: EyeLocating {
    static let left = CGRect(x: 100, y: 120, width: 96, height: 96)
    static let right = CGRect(x: 300, y: 120, width: 96, height: 96)
    /// One square over both eyes: painted, both read "closed".
    static let both = left.union(right)

    var lost: Set<Int> = []
    private(set) var searches = 0

    func locate(in pixelBuffer: CVPixelBuffer) throws -> LocatedEyes? {
        defer { searches += 1 }
        guard !lost.contains(searches) else { return nil }
        func eye(_ side: EyeRegion.Side, _ rect: CGRect) -> EyeRegion {
            EyeRegion(side: side, cropRect: rect, center: CGPoint(x: rect.midX, y: rect.midY), openness: 0.25)
        }
        return LocatedEyes(faceRect: Self.both.insetBy(dx: -40, dy: -80), left: eye(.imageLeft, Self.left),
                           right: eye(.imageRight, Self.right), interocularDistance: 200, roll: nil, yaw: nil)
    }
}

/// Stands in for the model: an eye picture whose top is red is a closed eye.
struct RedIsClosed: EyeJudging {
    func closedProbability(of eye: CVPixelBuffer) throws -> Double {
        guard let image = EyeCropper.image(from: eye) else { return 0 }
        return Fixture.pixel(of: image, x: 32, y: 8).r > 180 ? 0.95 : 0.05
    }
}

@Suite("Replaying a capture from its whole frames")
struct ReplayTests {

    /// A capture of 40 frames numbered from 100 in which the eyes are "closed" (painted)
    /// on frames 110, 111 and 112: one blink, marked as a person would.
    private func capture() async throws -> URL {
        let folder = Fixture.temporaryFolder()
        try PrivateFolder.create(at: folder)
        let writer = WholeFrameWriter(folder: folder, patience: 5)
        for i in 0..<40 {
            let closed = (10...12).contains(i)
            let frame = Fixture.frame(width: 640, height: 360, target: closed ? PaintedEyes.both : .zero)
            #expect(writer.append(frame, frame: 100 + i, time: 5 + Double(i) / 30))
        }
        #expect(await writer.finish())
        try "id,first_frame,last_frame,kind,note\n1,110,112,blink,\n"
            .write(to: folder.appendingPathComponent("blinks.csv"), atomically: true, encoding: .utf8)
        return folder
    }

    private func replay(_ folder: URL, eyes: PaintedEyes = PaintedEyes(), everyFrame: Bool,
                        trace: CSVAppender? = nil) async throws -> CaptureReplay.Outcome {
        let reader = EyeReader(classifier: RedIsClosed(), finder: EyeFinder(locator: eyes))
        return try CaptureReplay.run(try await WholeFrameReader(folder: folder), reader: reader,
                                     everyFrame: everyFrame, trace: trace)
    }

    @Test("The blink painted in the stored frames is counted, once, where it happened",
          arguments: [true, false])
    func countsTheBlink(everyFrame: Bool) async throws {
        let folder = try await capture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let eyes = PaintedEyes()
        let outcome = try await replay(folder, eyes: eyes, everyFrame: everyFrame)

        #expect(outcome.lines.count == 40)
        #expect(outcome.lines.map(\.frame) == Array(100..<140))
        #expect(outcome.lines.filter { ($0.mean ?? 0) > 0.6 }.map(\.frame) == [110, 111, 112])
        // A blink is counted at the frame where the eyes are open again.
        #expect(RecordedCapture.counted(in: outcome.lines) == [113])
        // Every frame is read either way; the schedule only spares searches.
        #expect(eyes.searches == (everyFrame ? 40 : 20))

        let marks = try #require(try RecordedCapture.readMarks(folder.appendingPathComponent("blinks.csv")))
        let score = RecordedCapture.score(outcome.lines, against: marks)
        #expect(score.blinks == 1 && score.found == 1 && score.falseBlinks == 0)
        #expect(abs(score.seconds - 39.0 / 30) < 0.001)
    }

    @Test("A face lost during the closure: the blink is not guessed, and the comparison of two runs says what differs")
    func faceLost() async throws {
        let folder = try await capture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let whole = try await replay(folder, everyFrame: true)

        let eyes = PaintedEyes()
        eyes.lost = Set(11...30)        // from the second closed frame, for two thirds of a second
        let holed = try await replay(folder, eyes: eyes, everyFrame: true)
        #expect(holed.lines.count == 40)
        #expect(holed.lines[11...30].allSatisfy { $0.mean == nil && $0.left == nil })
        #expect(RecordedCapture.counted(in: holed.lines).isEmpty)

        let gap = CaptureReplay.difference(whole.lines, holed.lines)
        #expect(gap.compared == 20 && gap.readByOneOnly == 20)
        #expect(gap.largestGap == 0 && gap.otherSide == 0)
    }

    @Test("The blinks of two runs are paired when they are a frame or two apart; the others are named")
    func sameBlinks() {
        func run(_ counted: [Int]) -> [TraceLine] {
            (0..<300).map { TraceLine(frame: $0, time: Double($0) / 30, blink: counted.contains($0)) }
        }
        let same = CaptureReplay.sameBlinks(run([10, 50, 90]), run([11, 48, 90]))
        #expect(same.both == 3 && same.same)

        // 50 against 54 is too far to be the same blink; 200 is counted by the second run only.
        let other = CaptureReplay.sameBlinks(run([10, 50, 90]), run([10, 54, 90, 200]))
        #expect(other == CaptureReplay.SameBlinks(both: 2, onlyFirst: [50], onlySecond: [54, 200]))
        #expect(!other.same)

        // Two blinks close together are two blinks: each is paired once.
        #expect(CaptureReplay.sameBlinks(run([10, 12]), run([11])).onlyFirst == [12])
    }

    @Test("A replay's trace is written like the app's, and reads back as the lines it returned")
    func traceFile() async throws {
        let folder = try await capture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("replays/test.csv")
        let outcome = try await replay(folder, everyFrame: true,
                                       trace: try CSVAppender(url: file, header: CaptureWriter.header))

        let text = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(text.count == 41 && text[0] == CaptureWriter.header)
        #expect(text[11] == "110,5.3333,0.9500,0.9500,0.9500,0.2500,0.2500,closed,,,168.00,200.00")
        #expect(text[14] == "113,5.4333,0.0500,0.0500,0.0500,0.2500,0.2500,open,blink,,168.00,200.00")
        let read = try RecordedCapture.readTrace(file)
        #expect(read.map(\.frame) == outcome.lines.map(\.frame))
        #expect(read.map(\.mean) == outcome.lines.map(\.mean))
        #expect(read.map(\.blink) == outcome.lines.map(\.blink))
    }

    @Test("At the camera's pace, a replay lasts as long as the capture did, and reports what the stages cost")
    func cameraPace() async throws {
        let folder = try await capture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = EyeReader(classifier: RedIsClosed(), finder: EyeFinder(locator: PaintedEyes()))
        let start = Date()
        let outcome = try CaptureReplay.run(try await WholeFrameReader(folder: folder), reader: reader, atCameraPace: true)
        #expect(Date().timeIntervalSince(start) > 1.2, "40 frames at 30 a second are 1.3 s")
        #expect(RecordedCapture.counted(in: outcome.lines) == [113])
        let timings = try #require(outcome.timings)
        #expect(timings.analysedShare == 1 && timings.total > 0)
    }

    // MARK: A capture made by the app's own writer

    @Test("A capture asked to keep whole frames keeps them next to its trace; one that was not, does not")
    func captureWithWholeFrames() async throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let plain = try CaptureWriter(root: root, name: "plain")
        let whole = try CaptureWriter(root: root, name: "whole", wholeFrames: true)
        #expect(!plain.keepsWholeFrames && whole.keepsWholeFrames)
        for writer in [plain, whole] {
            for i in 0..<3 {
                writer.write(frame: 7 + i, time: Double(i) / 30, reading: FrameReading(), state: .unknown, event: nil,
                             tick: false, pixelBuffer: Fixture.frame(width: 640, height: 360))
                usleep(20_000)      // the encoder is given the time a camera would leave it
            }
        }
        #expect(await plain.finish())
        #expect(await whole.finish())

        #expect(!WholeFrameReader.hasFrames(plain.folder))
        #expect(plain.wholeFrames == 0 && whole.wholeFrames == 3)
        let reader = try await WholeFrameReader(folder: whole.folder)
        #expect(reader.count == 3)
        #expect(try reader.next()?.number == 7)

        // The folder reads back as a capture: its trace, and no marks yet.
        let recorded = try RecordedCapture(folder: whole.folder)
        #expect(recorded.trace.map(\.frame) == [7, 8, 9] && recorded.marks == nil)
        #expect(RecordedCapture.folders(in: root).map(\.lastPathComponent) == ["plain", "whole"])
    }
}

@Suite("Comparing a count with the blinks a person marked")
struct BlinkScoreTests {

    private let marks = [
        MarkedBlink(firstFrame: 100, lastFrame: 103, kind: .blink),
        MarkedBlink(firstFrame: 200, lastFrame: 202, kind: .none),
        MarkedBlink(firstFrame: 300, lastFrame: 302, kind: .partial),
        MarkedBlink(firstFrame: 400, lastFrame: 404, kind: .blink),
        MarkedBlink(firstFrame: 600, lastFrame: 603, kind: .blink),
    ]

    /// The same marks and the same counts are in training/tests/test_data_tools.py, with
    /// the same expected numbers: the two languages are held to one answer.
    @Test("Found, missed and false, as evaluate.py counts them")
    func score() {
        let counted = [
            108,    // just after the first blink (103 + 5): found
            109,    // one frame too late: no candidate there, false
            106,    // the first blink a second time: false
            203,    // on something marked 'none': false
            303,    // on a partial blink: neither found nor false
            398,    // two frames before the second blink's first frame: found
            500,    // nowhere near a candidate: false
        ]
        let score = BlinkScore(counted: counted, marks: marks, seconds: 60)
        #expect(score.blinks == 3 && score.found == 2 && score.missed == 1 && score.falseBlinks == 4)
        #expect(score.description == "  2 of   3 found ( 66.7%)    1 missed    4 false (4.0 a minute)")
        #expect((score + score).found == 4 && (score + score).seconds == 120)
    }

    @Test("Only frames where both eyes were read are judged: the marks cover nothing else")
    func oneEyeFrames() {
        // Frames 0...59; one blink marked on 20...22. The right eye is hidden on 23...30
        // and on 40...45 (head turned).
        func line(_ frame: Int, blink: Bool = false) -> TraceLine {
            let hidden = (23...30).contains(frame) || (40...45).contains(frame)
            return TraceLine(frame: frame, time: Double(frame) / 30, left: 0.1, right: hidden ? nil : 0.1,
                             mean: 0.1, blink: blink)
        }
        let marks = [MarkedBlink(firstFrame: 20, lastFrame: 22, kind: .blink)]

        // Counted at frame 31, the first with both eyes back: nine frames after the mark
        // by the clock, one position after it among the frames that were read. Found.
        var lines = (0..<60).map { line($0, blink: $0 == 31) }
        var score = RecordedCapture.score(lines, against: marks)
        #expect(score.found == 1 && score.falseBlinks == 0)

        // A blink counted while one eye was hidden: nobody was shown that moment, it is not judged.
        lines = (0..<60).map { line($0, blink: $0 == 42) }
        score = RecordedCapture.score(lines, against: marks)
        #expect(score.found == 0 && score.falseBlinks == 0 && score.missed == 1)

        // Counted far from any mark, both eyes read: false.
        lines = (0..<60).map { line($0, blink: $0 == 55) }
        #expect(RecordedCapture.score(lines, against: marks).falseBlinks == 1)
    }

    @Test("blinks.csv is read as marks; a capture not marked to the end has none")
    func readingMarks() throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("blinks.csv")
        #expect(try RecordedCapture.readMarks(file) == nil)

        try "id,first_frame,last_frame,kind,note\n1,100,103,blink,clear\n2,200,202,none,\n3,300,302,partial,half\n"
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(try RecordedCapture.readMarks(file) == Array(marks.prefix(3)))

        try "id,first_frame,last_frame,kind,note\n1,100,103,blink,\n2,200,202,,\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try RecordedCapture.readMarks(file) == nil)
    }

    @Test("trace.csv is read back as the app wrote it")
    func readingTrace() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var both = FrameReading()
        both.faceFound = true
        both.eyes = [EyeReading(side: .imageLeft, picture: nil, closed: 0.9, openness: 0.11),
                     EyeReading(side: .imageRight, picture: nil, closed: 0.7, openness: 0.12)]
        both.closed = 0.8
        let writer = try CaptureWriter(root: root, name: "c")
        writer.write(frame: 7, time: 0.2333, reading: both, state: .closed(since: 0.2, frames: 1, peak: 0.8), event: nil, tick: true)
        writer.write(frame: 8, time: 0.2667, reading: FrameReading(), state: .unknown, event: nil, tick: false)
        writer.write(frame: 9, time: 0.3, reading: both, state: .open, event: .blink(Blink(start: 0.2, end: 0.3)), tick: false)

        #expect(try RecordedCapture(folder: writer.folder).trace == [
            TraceLine(frame: 7, time: 0.2333, left: 0.9, right: 0.7, mean: 0.8),
            TraceLine(frame: 8, time: 0.2667),
            TraceLine(frame: 9, time: 0.3, left: 0.9, right: 0.7, mean: 0.8, blink: true),
        ])
    }
}
