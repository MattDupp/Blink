import Foundation
import CoreGraphics
import BlinkCore

/// What the painted person is asked to do.
enum PaintedAct: Equatable {
    /// Look at the screen, eyes open.
    case look
    /// Hold a pose of the recording script. `session`: which recording it is (each one is
    /// "recorded" in another light).
    case hold(Phase, session: Int)
    /// A tick was played: blink once.
    case blink
}

/// A person who is not there: decides, frame by frame, what the two painted eyes look like.
///
/// It obeys the instructions the way the script expects a person to: eyes closed during a
/// "closed" pose, a quick blink a quarter of a second after each tick. The same person at
/// every run, so that the demo's setup and the tests are repeatable.
struct PaintedPerson {

    private var act = PaintedAct.look
    private var blink: (start: Double, end: Double)?
    private var random = SeededRandom(seed: 20_261_121)
    /// A closed pose that will be held with the eyes open, once: (recording, pose), both
    /// counted from 0. What `PoseCheck` is there to catch.
    var mistake: (session: Int, phase: Int)?
    private var eyesStayOpen = false

    /// A blink of about 130 ms, 250 ms after the tick: four closed frames, like a real one.
    mutating func follow(_ act: PaintedAct, at time: Double) {
        if act == .blink {
            blink = (time + 0.25, time + 0.38)
        } else {
            self.act = act
            blink = nil
            eyesStayOpen = false
            if case .hold(let phase, let session) = act, let mistake, mistake.session == session,
               SessionScript.phases.firstIndex(of: phase) == mistake.phase {
                eyesStayOpen = true
                self.mistake = nil            // asked again, the pose is held as asked
            }
        }
    }

    /// The two eyes at `time` (the eye on the left of the picture first).
    mutating func eyes(at time: Double) -> [PaintedEye] {
        var eye = PaintedEye()
        var light = 0.7
        if case .hold(let phase, let session) = act {
            light = [0.72, 0.5, 0.62, 0.82][session % 4]       // each recording in another light
            eye.openness = phase.label == .open ? 0.9 : 0
            switch phase.variant {
            case "camera": eye.gaze.y = -0.6
            case "keyboard": (eye.openness, eye.gaze.y) = (0.5, 0.9)     // looking down: almost closed
            case "sides": eye.gaze.x = sin(time * 3)
            case "far": eye.scale = 0.78
            case "near": eye.scale = 1.22
            case "smile": eye.openness = 0.55
            case "tilt": eye.tilt = 0.3
            case "chin-down": eye.offset.y = 3
            case "turned": eye.offset.x = 4
            case "tight": eye.scale = 0.95
            default: break
            }
            if eyesStayOpen { eye.openness = 0.9 }
        }
        if let blink, time >= blink.start, time < blink.end { eye.openness = 0 }
        // Nobody holds perfectly still.
        eye.offset.x += Double(random.uniform(-2, 2))
        eye.offset.y += Double(random.uniform(-2, 2))
        eye.scale *= Double(random.uniform(0.97, 1.03))
        eye.light = light + Double(random.uniform(-0.03, 0.03))

        var other = eye
        other.noseOnRight = false
        other.light -= 0.06                                        // one side of a face is always darker
        return [eye, other]
    }
}

/// Stands in for the camera AND for the stage that finds the eyes, in the demo's setup and
/// in the tests: 30 times a second it hands the setup's pipeline two painted eye pictures.
///
/// From there on everything is the real thing. The pictures are saved by the code that
/// saves a camera's, a model is really trained on them, and the test at the end really
/// runs that model on painted blinks.
final class PaintedCamera: @unchecked Sendable {

    static let frameSize = CGSize(width: 1920, height: 1080)
    /// Where the two eyes would be in a camera picture.
    private static let squares = [CGRect(x: 760, y: 430, width: 130, height: 130), CGRect(x: 1030, y: 425, width: 130, height: 130)]

    private let queue = DispatchQueue(label: "blink.painted.frames", qos: .utility)
    private let person = Locked(PaintedPerson())
    private var timer: DispatchSourceTimer?

    /// Hands a frame to `pipeline` 30 times a second, on a background queue like the camera's.
    func start(into pipeline: SessionPipeline) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let time = ProcessInfo.processInfo.systemUptime
                pipeline.process(self.frame(at: time), frameSize: Self.frameSize, time: time)
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func follow(_ act: PaintedAct) {
        let time = ProcessInfo.processInfo.systemUptime
        person.withLock { $0.follow(act, at: time) }
    }

    /// The painted person will keep its eyes open through one closed pose, the first time
    /// it is asked for (`--painted-mistake`, and the tests of `PoseCheck`).
    func keepEyesOpen(session: Int, phase: Int) {
        person.withLock { $0.mistake = (session, phase) }
    }

    /// One frame's eyes, found and cut out.
    func frame(at time: Double) -> FoundEyes? {
        let eyes = person.withLock { $0.eyes(at: time) }
        let regions = zip([EyeRegion.Side.imageLeft, .imageRight], Self.squares).map { side, square in
            EyeRegion(side: side, cropRect: square, center: CGPoint(x: square.midX, y: square.midY), openness: 0.3)
        }
        let located = LocatedEyes(faceRect: CGRect(x: 640, y: 200, width: 640, height: 640), left: regions[0], right: regions[1],
                                  interocularDistance: regions[1].center.x - regions[0].center.x, roll: 0, yaw: nil)
        let crops = zip(eyes, regions).compactMap { eye, region in
            eye.buffer().map { EyeCrop(picture: $0, of: region) }
        }
        return FoundEyes(crops: crops, of: located)
    }
}
