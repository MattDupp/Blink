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
    public typealias FrameHandler = (_ pixelBuffer: CVPixelBuffer, _ time: Double) -> Void

    public enum CameraError: Error, CustomStringConvertible {
        case noCamera
        case cannotConfigure(String)

        public var description: String {
            switch self {
            case .noCamera: return "No camera was found on this Mac."
            case .cannotConfigure(let what): return "The camera could not be set up: \(what)."
            }
        }
    }

    private let session = AVCaptureSession()
    // "Utility" priority: macOS may run this work on the efficiency cores. Counting blinks
    // must not compete with what you are doing; a frame takes a few milliseconds of the
    // 33 available, so there is room. (The stage timings show it if that stops being true.)
    private let frameQueue = DispatchQueue(label: "blink.camera.frames", qos: .utility)
    private var onFrame: FrameHandler?

    /// Asks macOS for the camera. The first time, macOS shows its own permission window;
    /// afterwards it remembers the answer (System Settings > Privacy & Security > Camera).
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Builds the graph and starts the camera. `startRunning` blocks for a moment,
    /// so call this away from the main thread.
    public func start(onFrame: @escaping FrameHandler) throws {
        self.onFrame = onFrame

        // The built-in camera, not an iPhone that Continuity Camera may offer as "default".
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }
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

        // Never mirror: the pictures must be the same in the recorder and in the monitor.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        session.commitConfiguration()
        session.startRunning()
    }

    /// Turns the camera off (its green light goes out). The graph stays built.
    public func stop() {
        session.stopRunning()
    }

    /// Turns the camera back on after `stop`. Blocks for a moment like `start`.
    public func resume() {
        if !session.isRunning { session.startRunning() }
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
