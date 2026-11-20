import CoreGraphics
import Foundation
import Testing
@testable import BlinkCore

@Suite("Files written by the recorder and the captures")
struct RecordingTests {

    private let target = CGRect(x: 1000, y: 200, width: 128, height: 128)

    private func sample(_ image: CGImage, label: EyeLabel = .closed) -> EyeSample {
        let eye = EyeRegion(side: .imageLeft, cropRect: target, center: CGPoint(x: target.midX, y: target.midY))
        let other = EyeRegion(side: .imageRight, cropRect: target.offsetBy(dx: 200, dy: 0),
                              center: CGPoint(x: target.midX + 200, y: target.midY))
        let located = LocatedEyes(faceRect: .zero, left: eye, right: other, interocularDistance: 200, roll: 0.05, yaw: nil)
        return EyeSample(image: image, label: label, variant: "gentle", phaseIndex: 1, frameIndex: 42, time: 1.5,
                         eye: eye, located: located, frameSize: CGSize(width: 1920, height: 1080))
    }

    // MARK: Recording sessions

    @Test("A session on disk: its folders, a readable PNG, one manifest line per picture")
    func sessionOnDisk() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try #require(EyeCropper().crop(Fixture.frame(target: target), rect: target))

        // The condition is typed by the user: its commas and quotes must not break the CSV.
        let writer = try SessionWriter(root: root, session: "test", condition: "lamp, \"glasses\"")
        #expect(writer.save(sample(image)))

        let saved = try #require(PNGFile.read(root.appendingPathComponent("test/closed/p01_f000042_L.png")))
        #expect(saved.width == 64 && saved.height == 64)

        let manifest = try String(contentsOf: root.appendingPathComponent("test/manifest.csv"), encoding: .utf8)
        let lines = manifest.split(separator: "\n").map(String.init)
        try #require(lines.count == 2)
        #expect(lines[0] == SessionWriter.header)
        #expect(lines[1] == "test,lamp glasses,1,closed,gentle,42,1.500,L,closed/p01_f000042_L.png,1000,200,128,200.0,0.050,,1920,1080")

        #expect(DatasetStats.scan(root) == DatasetStats(sessions: 1, open: 0, closed: 1))
    }

    @Test("Discarding the latest session removes it whole and keeps the others")
    func discard() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try #require(EyeCropper().crop(Fixture.frame(target: target), rect: target))
        try SessionWriter(root: root, session: "20270101-090000", condition: "").save(sample(image, label: .open))
        _ = try SessionWriter(root: root, session: "20270101-100000", condition: "")

        let latest = try #require(SessionStore.latest(in: root))
        #expect(latest.lastPathComponent == "20270101-100000")
        try SessionStore.discard(latest, toTrash: false)

        #expect(!FileManager.default.fileExists(atPath: latest.path))
        #expect(SessionStore.latest(in: root)?.lastPathComponent == "20270101-090000")
        #expect(DatasetStats.scan(root) == DatasetStats(sessions: 1, open: 1, closed: 0))
    }

    // MARK: Captures

    @Test("A capture keeps every frame's pictures and one trace line per frame")
    func capture() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cropper = EyeCropper()
        let picture = try #require(cropper.cropBuffer(Fixture.frame(target: target), rect: target))

        var both = FrameReading()
        both.faceFound = true
        both.eyes = [EyeReading(side: .imageLeft, picture: picture, closed: 0.9, openness: 0.11),
                     EyeReading(side: .imageRight, picture: picture, closed: 0.7, openness: 0.12)]
        both.closed = 0.8

        let writer = try CaptureWriter(root: root, name: "test")
        writer.write(frame: 7, time: 0.2333, reading: both, state: .closed(since: 0.2, frames: 1), event: nil, tick: true)
        writer.write(frame: 8, time: 0.2667, reading: FrameReading(), state: .unknown, event: nil, tick: false)

        for side in ["L", "R"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("test/frames/f000007_\(side).png").path))
        }
        let lines = try String(contentsOf: root.appendingPathComponent("test/trace.csv"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines == [
            CaptureWriter.header,
            "7,0.2333,0.9000,0.7000,0.8000,0.1100,0.1200,closed,,1",
            "8,0.2667,,,,,,unknown,,",
        ])
        #expect(writer.frames == 2)
    }
}
