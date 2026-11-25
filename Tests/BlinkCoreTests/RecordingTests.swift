import CoreGraphics
import Foundation
import Testing
@testable import BlinkCore

@Suite("Files written by recorded sessions and captures")
struct RecordingTests {

    @Test("The end of a closed-eye pose changes the window's brightness once, softly, and never as a flicker")
    func poseSignal() {
        let real = SessionPace()
        // Eyes open: the page is seen, nothing is added. The demo's painted eyes: nothing either.
        #expect(PoseSignal.atEnd(of: .open, pace: real, reduceMotion: false) == .none)
        #expect(PoseSignal.atEnd(of: .closed, pace: .painted, reduceMotion: false) == .none)
        // Reduce Motion: no rise and fall, a steady change.
        #expect(PoseSignal.atEnd(of: .closed, pace: real, reduceMotion: true) == .steady)

        let pulse = PoseSignal.atEnd(of: .closed, pace: real, reduceMotion: false)
        guard case .pulse(let rise, _, let fall) = pulse else { Issue.record("no pulse"); return }
        // Soft: neither edge is abrupt.
        #expect(rise >= 0.3 && fall >= 0.3)
        // One at a time: a brightening is over before the next pose could end.
        #expect(pulse.seconds < PoseSignal.shortestGap(pace: real))
        // Far under three flashes a second, the line for photosensitive epilepsy:
        // at most one every four seconds, and the spoken instruction makes it rarer.
        #expect(1 / PoseSignal.shortestGap(pace: real) <= 0.25)
        // Never a blank screen, and the steady change is the weaker one: the page stays readable.
        #expect(pulse.strength < 1 && PoseSignal.steady.strength < pulse.strength && PoseSignal.none.strength == 0)
        // A dark window brightens; a light one cannot, so it dims and comes back.
        #expect(PoseSignal.change(windowIsDark: true) == .brighter && PoseSignal.change(windowIsDark: false) == .darker)
    }

    @Test("With VoiceOver on, the spoken lines go to VoiceOver, and the script waits long enough for each")
    func spokenGuide() {
        #expect(SpokenGuide.channel(voiceOverOn: false) == .ownVoice)
        #expect(SpokenGuide.channel(voiceOverOn: true) == .voiceOver)
        // Nothing to say: no wait. One word: a second, since VoiceOver needs a moment to start.
        #expect(SpokenGuide.seconds(toSay: "") == 0)
        #expect(SpokenGuide.seconds(toSay: "Halfway.") == 1)
        // Six words at three words a second, and half a second to start.
        #expect(abs(SpokenGuide.seconds(toSay: "Finished. You can open your eyes.") - 2.5) < 0.001)
        // Every line of the script is given time, and none holds a pose up for long.
        for phase in SessionScript.phases {
            let wait = SpokenGuide.seconds(toSay: phase.instruction)
            #expect(wait >= 1 && wait < 8, "\(phase.instruction)")
        }
    }

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

        #expect(SessionStore.sessions(in: root).map(\.pictures) == [1])
    }

    @Test("A CSV file gets its header once, then one line per call - also when reopened")
    func csvAppender() throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("deep/log.csv")      // the folder does not exist yet

        #expect(try CSVAppender(url: file, header: "a,b").append(["1", "2"]))
        let reopened = try CSVAppender(url: file, header: "a,b")
        #expect(reopened.append(["3", "4"]))
        #expect(reopened.append(["5", "6"]))

        #expect(try String(contentsOf: file, encoding: .utf8) == "a,b\n1,2\n3,4\n5,6\n")
    }

    @Test("The performance log writes one readable line per minute")
    func performanceLog() throws {
        let folder = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var summary = StageTimings.Summary()
        summary.findEyes = 6.4
        summary.crop = 1.3
        summary.model = 0.7
        summary.total = 8.6
        summary.worstTotal = 21.5
        summary.framesPerSecond = 30
        summary.analysedShare = 0.5

        let log = PerformanceLog(file: folder.appendingPathComponent("performance.csv"))
        log.append(summary, at: Date(timeIntervalSince1970: 1_800_000_000))
        let lines = try String(contentsOf: log.file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == [
            "time,frames_per_second,analysed_share,find_eyes_ms,crop_ms,model_ms,frame_ms,worst_frame_ms",
            "2027-01-15T08:00:00Z,30.0,0.50,6.40,1.30,0.70,8.60,21.5",
        ])
    }

    @Test("Text typed by the user cannot break the CSV or become a spreadsheet formula")
    func conditionText() {
        #expect(CSVAppender.safe("lamp, \"glasses\"\nevening") == "lamp glasses evening")
        #expect(CSVAppender.safe("=HYPERLINK(\"x\")") == "HYPERLINK( x )")
        #expect(CSVAppender.safe(" +-@ daylight") == "daylight")
        #expect(CSVAppender.safe("no glasses - evening") == "no glasses - evening")
    }

    @Test("Recordings are written to folders only their owner can read")
    func privateFolders() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try SessionWriter(root: root, session: "s", condition: "")
        _ = try CaptureWriter(root: root, name: "c")
        for path in ["s", "s/open", "c", "c/frames"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            #expect(attributes[.posixPermissions] as? Int == 0o700, "\(path)")
        }
    }

    @Test("Discarding the latest session removes it whole and keeps the others")
    func discard() throws {
        let root = Fixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try #require(EyeCropper().crop(Fixture.frame(target: target), rect: target))
        try SessionWriter(root: root, session: "20270101-090000", condition: "").save(sample(image, label: .open))
        _ = try SessionWriter(root: root, session: "20270101-100000", condition: "")

        let latest = root.appendingPathComponent("20270101-100000", isDirectory: true)
        try SessionStore.discard(latest, toTrash: false)

        #expect(!FileManager.default.fileExists(atPath: latest.path))
        let left = SessionStore.sessions(in: root)
        #expect(left.map(\.name) == ["20270101-090000"] && left.map(\.open) == [1] && left.map(\.closed) == [0])
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
        writer.write(frame: 7, time: 0.2333, reading: both, state: .closed(since: 0.2, frames: 1, peak: 0.8), event: nil, tick: true)
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
