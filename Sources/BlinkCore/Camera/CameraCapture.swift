import AVFoundation
import CoreVideo

/// Opens the MacBook's camera and hands over every frame it produces.
///
/// AVFoundation models a camera as a small graph:
///
///     device (the camera) -> input -> SESSION -> output -> our delegate method
///
/// The session runs on its own threads. About 30 times a second it calls `captureOutput`
/// with one frame, on the background queue we gave it - never on the main (UI) thread,
/// so a slow frame can never freeze the window.
public final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    /// Called for every frame, on the camera's background queue.
    /// - pixelBuffer: the raw picture (a block of memory holding the pixels).
    /// - time: the frame's capture time in seconds (the camera's own clock). The blink
    ///   detector will later measure blink durations with it.
    public typealias FrameHandler = @Sendable (_ pixelBuffer: CVPixelBuffer, _ time: Double) -> Void

    public enum CameraError: Error, CustomStringConvertible {
        /// macOS (that is, the user) refused the camera.
        case refused
        case noCamera
        case cannotConfigure(String)

        public var description: String {
            switch self {
            case .refused: return "Camera access was refused."
            case .noCamera: return "No camera was found on this Mac."
            case .cannotConfigure(let what): return "The camera could not be set up: \(what)."
            }
        }
    }

    /// The camera in use, as macOS names it ("FaceTime HD Camera"). Nil before `start`.
    public var deviceName: String? { device.withLock { $0?.name } }
    /// The same camera, as macOS knows it (`CameraOption.id`).
    public var deviceID: String? { device.withLock { $0?.id } }
    /// Written on the session's queue, read by the windows: behind a lock.
    private let device = Locked<(name: String, id: String)?>(nil)
    /// The camera the user chose; nil for Automatic (`CameraChoice`). Set before `start`.
    public var wantedCamera: String? {
        get { wantedDevice.withLock { $0 } }
        set { wantedDevice.withLock { $0 = newValue } }
    }
    private let wantedDevice = Locked<String?>(nil)

    private let session = AVCaptureSession()
    /// EVERY CALL THAT TOUCHES THE SESSION RUNS HERE, one at a time, in the order asked.
    /// Starting and stopping block while the camera wakes or sleeps, so they are kept off
    /// the main thread; and a session must not be reconfigured on two threads at once. The
    /// first versions sent each call to the shared global queue instead, from seven places,
    /// where a pause and a change of camera could reach the session together.
    private let sessionQueue = DispatchQueue(label: "blink.camera.session", qos: .userInitiated)
    /// The camera is meant to be running (it was started, and not stopped since).
    private let wanted = Locked(false)
    private var errorObserver: NSObjectProtocol?
    // "Utility" priority: macOS may run this work on the efficiency cores. Counting blinks
    // must not compete with what you are doing; a frame takes a few milliseconds of the
    // 33 available, so there is room. (The stage timings show it if that stops being true.)
    private let frameQueue = DispatchQueue(label: "blink.camera.frames", qos: .utility)
    private var onFrame: FrameHandler?

    /// Asks for the camera, then starts it. Returns once frames are on their way; throws
    /// `CameraError.refused` when the permission is not given.
    ///
    /// Counting and the setup start the camera through this one call: the permission question, and
    /// the hop off the main thread that `startRunning` needs (it blocks while the camera
    /// wakes up), are written once.
    public func start(onFrame: @escaping FrameHandler) async throws {
        guard await Self.requestPermission() else { throw CameraError.refused }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.startSession(onFrame: onFrame)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Asks macOS for the camera. The first time, macOS shows its own permission window;
    /// afterwards it remembers the answer (System Settings > Privacy & Security > Camera).
    private static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Builds the graph and starts the camera. On the session's queue: `startRunning`
    /// blocks for a moment.
    private func startSession(onFrame: @escaping FrameHandler) throws {
        self.onFrame = onFrame

        guard let device = Self.pickCamera(wanted: wantedCamera) else { throw CameraError.noCamera }
        self.device.withLock { $0 = (device.localizedName, device.uniqueID) }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()

        // 1920x1080: at a normal sitting distance one eye is then roughly 90 pixels wide,
        // comfortably more than the 64x64 picture we keep. At 1280x720 the eye would be
        // about 60 pixels: we would be ENLARGING it, inventing pixels that carry no information.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        guard session.canAddInput(input) else { throw CameraError.cannotConfigure("input refused") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // BGRA = 4 bytes per pixel (blue, green, red, alpha). The camera's native format is
        // YUV; asking for BGRA makes AVFoundation convert it, and every later stage
        // (Vision, Core Image, Core ML) accepts BGRA directly.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // If we are still busy with a frame when the next one arrives, drop the new one
        // instead of queueing it: for live monitoring a late frame is worthless.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)

        guard session.canAddOutput(output) else { throw CameraError.cannotConfigure("output refused") }
        session.addOutput(output)

        // Never mirror: the pictures must be the same when they are recorded and when they are read.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        session.commitConfiguration()

        // A session can stop by itself (the camera's driver restarted, the device was
        // taken away for a moment). Without this it would stay stopped, and the app
        // would go on showing its last number.
        errorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.app.error("Camera stopped: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
            self?.sessionQueue.asyncAfter(deadline: .now() + 2) { self?.recoverNow() }
        }

        wanted.withLock { $0 = true }
        session.startRunning()
    }

    /// The camera to use: the Mac's own; on a Mac that has none, the first one plugged in.
    ///
    /// NOT simply "the default camera". With an iPhone nearby, macOS can offer the phone
    /// as the default (Continuity Camera) - and, unless the app's Info.plist sets
    /// NSCameraUseContinuityCameraDeviceType, it even reports that phone as a "built-in
    /// wide angle camera". The app sets the key, so here a built-in camera is the Mac's.
    private static func pickCamera(wanted: String? = nil) -> AVCaptureDevice? {
        let found = devices()
        let picked = CameraChoice.pick(from: found.map(Self.option), wanted: wanted)
        return found.first { $0.uniqueID == picked?.id } ?? AVCaptureDevice.default(for: .video)
    }

    private static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                         mediaType: .video, position: .unspecified).devices
    }

    private static func option(_ device: AVCaptureDevice) -> CameraOption {
        CameraOption(id: device.uniqueID, name: device.localizedName, builtIn: device.deviceType == .builtInWideAngleCamera)
    }

    /// The cameras this Mac offers now, the Mac's own first.
    public static func options() -> [CameraOption] {
        let all = devices().map(option)
        return all.filter(\.builtIn) + all.filter { !$0.builtIn }
    }

    /// Moves a camera that is built to another device: the user chose it, or the one in
    /// use sent nothing (`CameraChoice.fallback`). Returns at once; the change is made on
    /// the session's queue. Nothing changes when the device is gone, or would not be added.
    public func use(camera id: String) {
        sessionQueue.async { self.switchTo(camera: id) }
    }

    private func switchTo(camera id: String) {
        guard id != deviceID, let device = Self.devices().first(where: { $0.uniqueID == id }),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        let old = session.inputs
        old.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else {
            old.forEach { if session.canAddInput($0) { session.addInput($0) } }
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        // A new input makes a new connection: it must not be mirrored either.
        for output in session.outputs {
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        session.commitConfiguration()
        self.device.withLock { $0 = (device.localizedName, device.uniqueID) }
        Log.app.notice("Camera changed to \(device.localizedName, privacy: .private)")
    }

    /// Turns the camera off (its green light goes out). The graph stays built. Returns at
    /// once, like the three below: the work is done on the session's queue, in order.
    public func stop() {
        wanted.withLock { $0 = false }
        sessionQueue.async { self.session.stopRunning() }
    }

    /// Turns the camera back on after `stop`.
    public func resume() {
        wanted.withLock { $0 = true }
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    /// The same, returning once the camera runs again.
    public func resumeAndWait() async {
        wanted.withLock { $0 = true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
                continuation.resume()
            }
        }
    }

    /// Starts the camera again if it stopped BY ITSELF. Does nothing when it runs, and
    /// nothing when it was stopped on purpose: a pause must stay a pause.
    public func recover() {
        sessionQueue.async { self.recoverNow() }
    }

    private func recoverNow() {
        guard wanted.withLock({ $0 }), !session.isRunning else { return }
        session.startRunning()
    }

    // AVFoundation calls this for every frame, on `frameQueue`.
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        // The frameworks called for each frame create temporary objects that are only
        // freed when an "autorelease pool" is emptied. On a queue that never rests, that
        // can be much later; a pool per frame frees them before the next frame arrives.
        autoreleasepool {
            onFrame?(pixelBuffer, time)
        }
    }
}
