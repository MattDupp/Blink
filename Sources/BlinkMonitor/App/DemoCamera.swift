import Foundation
import CoreGraphics
import BlinkCore

/// What delivers frames to the model: the camera, or the demo's stand-in for it.
protocol FrameSource: AnyObject, Sendable {
    func stop()
    func resume()
    /// Start again if it stopped by itself (see `CameraCapture.recover`).
    func recover()
}

extension CameraCapture: FrameSource {}

/// Made-up eyes: what 30 frames a second would say about someone at a screen, who blinks
/// every few seconds.
///
/// It replaces the camera AND the model, nothing else. Its readings go through the real
/// blink detector, the real statistics, the real history: what the demo shows is the app
/// working, on eyes that do not exist.
struct DemoEyes {

    enum Pace {
        /// A blink of about 130 ms every 2.6 to 6.4 s: about 13 a minute.
        case usual
        /// A blink break: slow, full blinks of about a second, one after the other.
        case exercise
    }

    /// Changing the pace forgets the blink that was planned: the new pace starts at once.
    var pace = Pace.usual { didSet { if pace != oldValue { planned = nil } } }

    private var planned: (start: Double, end: Double)?
    private var seed: UInt64

    init(seed: UInt64 = 20_261_120) {
        self.seed = seed
    }

    /// A number in 0..<1: a small fixed generator, so that the demo is the same every time.
    private mutating func random() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 33) / Double(1 << 31)
    }

    /// What the frame at `time` says. Call it with times that only increase.
    mutating func reading(at time: Double) -> FrameReading {
        if planned.map({ time > $0.end + 0.1 }) ?? true {
            let (wait, length) = pace == .usual
                ? (2.6 + random() * 3.8, 0.10 + random() * 0.07)
                : (1.0 + random() * 0.6, 0.8 + random() * 0.4)
            planned = (time + wait, time + wait + length)
        }
        let blink = planned ?? (time, time)
        let frame = 1.0 / 30
        let closed: Double
        if time >= blink.start && time < blink.end {
            closed = 0.97
        } else if time >= blink.start - frame && time < blink.end + frame {
            closed = 0.45                    // the lid on its way down, or up
        } else {
            closed = 0.02
        }

        var reading = FrameReading()
        reading.faceFound = true
        reading.eyeRects = [CGRect(x: 760, y: 430, width: 130, height: 130), CGRect(x: 1030, y: 425, width: 130, height: 130)]
        reading.eyes = [EyeReading(side: .imageLeft, picture: nil, closed: min(1, closed + 0.01), openness: 0.3),
                        EyeReading(side: .imageRight, picture: nil, closed: max(0, closed - 0.01), openness: 0.3)]
        reading.closed = EyeFusion.combine(reading.eyes.map(\.closed))
        return reading
    }
}

/// Stands in for the camera in the demo: calls back 30 times a second with what the
/// made-up eyes are doing. No camera is opened and no picture exists.
final class DemoCamera: FrameSource, @unchecked Sendable {

    private let queue = DispatchQueue(label: "blink.demo.frames", qos: .utility)
    private let eyes = Locked(DemoEyes())
    private var timer: DispatchSourceTimer?
    private var onFrame: ((FrameReading, Double) -> Void)?

    /// `onFrame` is called on a background queue, like the camera's.
    func start(onFrame: @escaping (FrameReading, Double) -> Void) {
        queue.async { self.onFrame = onFrame }
        resume()
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let time = ProcessInfo.processInfo.systemUptime
                let reading = self.eyes.withLock { $0.reading(at: time) }
                self.onFrame?(reading, time)
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

    /// Made-up eyes do not fail.
    func recover() {}

    func setPace(_ pace: DemoEyes.Pace) {
        eyes.withLock { $0.pace = pace }
    }
}
