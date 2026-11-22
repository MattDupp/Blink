import Foundation
import CoreGraphics
import CoreVideo

/// What one processed frame tells the setup window.
public struct SessionFrame {
    /// The frame's time, on the camera's clock.
    public var time = 0.0
    public var preview: CGImage?
    public var frameSize: CGSize = .zero
    public var eyeRects: [CGRect] = []
    public var faceFound = false
    /// The side of the square cut around each eye, in camera pixels.
    public var cropSide = 0
    /// The pictures that would be saved, as shown beside the camera. An eye that is not
    /// usable in this frame is missing: what is shown is what is saved.
    public var leftCrop: CGImage?
    public var rightCrop: CGImage?
    /// The average brightness of the eye pictures, 0 (black) to 255 (white).
    public var brightness: Double?
    public var savedOpen = 0
    public var savedClosed = 0

    // While a model is being tested (`SessionPipeline.setJudge`):
    /// The model's answer for this frame, the two eyes combined.
    public var closed: Double?
    public var eyesClosed = false
    /// A blink ended on this frame.
    public var blink: Blink?
    /// A tick was played just before this frame.
    public var tick = false

    public var error: String?

    public init() {}
}

/// The work done on every frame while the app is being set up, in order:
///
///     frame -> EyeFinder (find the eyes, cut 64x64 pictures) -> save them   (recording)
///     frame -> EyeReader (the same, then the model) -> BlinkDetector        (the test)
///
/// `EyeFinder` is the very stage the monitor reads its eyes through, so the pictures saved
/// here are made exactly like the ones the model will be asked about - and the test at the
/// end of setup reads frames the way everyday monitoring will.
///
/// It runs on the camera's background queue. The session script runs on the main thread
/// and only tells it WHAT is being recorded or tested.
public final class SessionPipeline: @unchecked Sendable {

    public struct Recording {
        public let writer: SessionWriter
        public let phaseIndex: Int
        public let phase: Phase

        public init(writer: SessionWriter, phaseIndex: Int, phase: Phase) {
            self.writer = writer
            self.phaseIndex = phaseIndex
            self.phase = phase
        }
    }

    /// What the main thread asks, taken in at the start of each frame.
    private struct Requests {
        var recording: Recording?
        var judge: EyeJudging?
        var judgeChanged = false
        var tick = false
    }

    /// Called on the camera queue after every frame.
    public var onUpdate: ((SessionFrame) -> Void)?

    private let pace: SessionPace
    private let finder = EyeFinder()
    private let requests = Locked(Requests())
    private var reader: EyeReader?
    private var judge: EyeJudging?
    private var detector = BlinkDetector()
    private var frameIndex = 0

    public init(pace: SessionPace = .usual) {
        self.pace = pace
    }

    // MARK: - Requests from the main thread

    /// Starts (a recording) or stops (nil) saving the frames' eye pictures.
    public func setRecording(_ value: Recording?) {
        requests.withLock { $0.recording = value }
    }

    /// Starts (a model) or stops (nil) reading the eyes with a model and counting blinks.
    public func setJudge(_ judge: EyeJudging?) {
        requests.withLock {
            $0.judge = judge
            $0.judgeChanged = true
        }
    }

    /// A tick was just played: the next frame carries it.
    public func markTick() {
        requests.withLock { $0.tick = true }
    }

    private func takeRequests() -> Requests {
        frameIndex += 1
        let asked = requests.withLock { requests in
            defer {
                requests.tick = false
                requests.judgeChanged = false
            }
            return requests
        }
        if asked.judgeChanged {
            judge = asked.judge
            reader = asked.judge.map { EyeReader(classifier: $0) }
            detector.reset()
        }
        return asked
    }

    // MARK: - Every frame

    /// A frame from the camera.
    public func process(_ pixelBuffer: CVPixelBuffer, time: Double) {
        let asked = takeRequests()
        var update = SessionFrame()
        update.time = time
        update.tick = asked.tick
        update.frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        do {
            if let reader {
                // The test: the frame is read as the monitor reads it.
                if let reading = try reader.read(pixelBuffer)?.reading {
                    update.faceFound = reading.faceFound
                    update.eyeRects = reading.eyeRects
                    for eye in reading.eyes {
                        let image = eye.picture.flatMap(EyeCropper.image(from:))
                        if eye.side == .imageLeft { update.leftCrop = image } else { update.rightCrop = image }
                    }
                    count(reading.closed, into: &update)
                }
            } else {
                // Recording, and the check before it: the eyes are searched for on every
                // frame, so that each saved picture gets its own, fresh square.
                var cost = FrameCost()
                if case .found(let found) = try finder.find(in: pixelBuffer, everyFrame: true, cost: &cost) {
                    show(found, in: &update)
                    if frameIndex % pace.saveEveryNthFrame == 0, let recording = asked.recording {
                        save(found, to: recording, update: &update)
                    }
                }
            }
        } catch {
            update.error = "The eyes could not be searched for: \(error.localizedDescription)"
        }

        // The window shows every second frame: 15 pictures a second look live enough,
        // and converting a full frame for display is the most expensive step here.
        if frameIndex % 2 == 0 {
            update.preview = finder.preview(pixelBuffer, maxWidth: 800)
        }
        onUpdate?(update)
    }

    /// Eyes that were found and cut out already (nil: no face). Painted eyes enter here:
    /// from this point on they are saved, judged and counted by the code that handles a
    /// camera's.
    public func process(_ found: FoundEyes?, frameSize: CGSize, time: Double) {
        let asked = takeRequests()
        var update = SessionFrame()
        update.time = time
        update.tick = asked.tick
        update.frameSize = frameSize
        if let found {
            show(found, in: &update)
            if let judge {
                do {
                    let answers = try found.crops.map { try judge.closedProbability(of: $0.picture) }
                    count(EyeFusion.combine(answers), into: &update)
                } catch {
                    update.error = "\(error)"
                }
            } else if frameIndex % pace.saveEveryNthFrame == 0, let recording = asked.recording {
                save(found, to: recording, update: &update)
            }
        } else if judge != nil {
            count(nil, into: &update)
        }
        onUpdate?(update)
    }

    private func count(_ closed: Double?, into update: inout SessionFrame) {
        update.closed = closed
        if case .blink(let blink) = detector.update(time: update.time, closed: closed) { update.blink = blink }
        if case .closed = detector.state { update.eyesClosed = true }
    }

    private func show(_ found: FoundEyes, in update: inout SessionFrame) {
        update.faceFound = true
        update.eyeRects = found.located.usableEyes.map(\.cropRect)
        update.cropSide = Int(found.located.left.cropRect.width)
        var levels: [Double] = []
        for crop in found.crops {
            let image = EyeCropper.image(from: crop.picture)
            if crop.region.side == .imageLeft { update.leftCrop = image } else { update.rightCrop = image }
            if let level = Self.brightness(of: crop.picture) { levels.append(level) }
        }
        if !levels.isEmpty { update.brightness = levels.reduce(0, +) / Double(levels.count) }
    }

    /// Saves the frame's pictures - only when every usable eye was cut cleanly.
    private func save(_ found: FoundEyes, to current: Recording, update: inout SessionFrame) {
        guard found.isComplete else { return }
        for crop in found.crops {
            guard let image = EyeCropper.image(from: crop.picture) else { continue }
            let saved = current.writer.save(EyeSample(
                image: image, label: current.phase.label, variant: current.phase.variant,
                phaseIndex: current.phaseIndex, frameIndex: frameIndex, time: update.time,
                eye: crop.region, located: found.located, frameSize: update.frameSize))
            if !saved {
                update.error = "A picture could not be written to disk."
            } else if current.phase.label == .open {
                update.savedOpen += 1
            } else {
                update.savedClosed += 1
            }
        }
    }

    /// The average brightness of an eye picture, 0 to 255 (the model's own mix of colours).
    static func brightness(of picture: CVPixelBuffer) -> Double? {
        guard let gray = TrainingSet.gray(of: picture) else { return nil }
        return Double(gray.reduce(0, +)) / Double(gray.count) * 255
    }
}

// Eyes that are handed over ready-made (painted ones: see `process(_:frameSize:time:)`).
// The labels differ from the stored properties' on purpose: Swift already makes an
// initialiser with those, for this module only.
extension EyeCrop {
    public init(picture: CVPixelBuffer, of region: EyeRegion) {
        self.init(region: region, picture: picture)
    }
}

extension FoundEyes {
    public init(crops: [EyeCrop], of located: LocatedEyes) {
        self.init(located: located, crops: crops)
    }
}
