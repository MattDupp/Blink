import SwiftUI
import AppKit
import BlinkCore

/// The recorder's state: everything the window shows, and the session script that drives it.
///
/// `@MainActor` = every property here is read and written on the main thread only, the one
/// that draws the window. The camera works on another thread and hands its results over
/// (`apply`). `@Published` = when the value changes, SwiftUI redraws what depends on it.
@MainActor
final class RecorderModel: ObservableObject {

    enum Stage: Equatable {
        case starting
        case denied
        case failed(String)
        case ready
        case running
    }

    enum PhaseState {
        case idle, listening, settling, recording
    }

    @Published var stage: Stage = .starting
    @Published var phaseState: PhaseState = .idle
    @Published var phaseIndex = 0
    @Published var currentLabel: EyeLabel?
    @Published var prompt = "Starting the camera..."
    @Published var recordProgress = 0.0

    @Published var preview: CGImage?
    @Published var frameSize = CGSize(width: 1920, height: 1080)
    @Published var eyeRects: [CGRect] = []
    @Published var faceFound = false
    @Published var cropSide = 0
    @Published var leftCrop: CGImage?
    @Published var rightCrop: CGImage?

    @Published var sessionOpen = 0
    @Published var sessionClosed = 0
    @Published var dataset = DatasetStats()
    @Published var lastSessionFolder: URL?
    @Published var condition = ""
    @Published var problem: String?
    /// True while the "Move session ... to the Trash?" question is on screen. It lives here
    /// and not in the view as `@State`: in this macOS SDK `@State` is a compiler plug-in
    /// that ships with Xcode only, and this project builds without Xcode.
    @Published var confirmingDiscard = false

    let outputRoot: URL

    private let camera = CameraCapture()
    private let pipeline = FramePipeline()
    private let speaker = Speaker()
    private var sessionTask: Task<Void, Never>?

    init(outputRoot: URL) {
        self.outputRoot = outputRoot
    }

    // MARK: - Camera

    func start() async {
        guard stage == .starting else { return }
        dataset = DatasetStats.scan(outputRoot)
        lastSessionFolder = SessionStore.latest(in: outputRoot)

        if Options.noCamera {
            stage = .failed("The camera is off (--no-camera).")
            prompt = "Window check: the camera is off."
            return
        }

        guard await CameraCapture.requestPermission() else {
            stage = .denied
            prompt = "Camera access was refused."
            return
        }

        pipeline.onUpdate = { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }

        // startRunning blocks while the camera wakes up: do it off the main thread.
        let camera = self.camera, pipeline = self.pipeline
        let failure: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try camera.start { pixelBuffer, time in pipeline.process(pixelBuffer, time: time) }
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: "\(error)")
                }
            }
        }

        if let failure {
            stage = .failed(failure)
            prompt = failure
        } else {
            stage = .ready
            prompt = "Check that the two green squares sit on your eyes, then start a session."
        }
    }

    private func apply(_ update: FrameUpdate) {
        if let image = update.preview { preview = image }
        frameSize = update.frameSize
        eyeRects = update.eyeRects
        faceFound = update.faceFound
        if update.faceFound {
            cropSide = update.cropSide
            // An eye that is not usable in this frame shows as a black square: what you
            // see here is what would be saved.
            leftCrop = update.leftCrop
            rightCrop = update.rightCrop
        }
        sessionOpen += update.savedOpen
        sessionClosed += update.savedClosed
        if let error = update.error { problem = error }
    }

    // MARK: - Session

    func startSession() {
        guard stage == .ready else { return }
        stage = .running
        sessionTask = Task { await runSession() }
    }

    func stopSession() {
        sessionTask?.cancel()
        speaker.stop()
    }

    func revealData() {
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([lastSessionFolder ?? outputRoot])
    }

    /// Throws the most recent session away - the way to redo a session that went wrong.
    /// It goes to the Trash, so it can still be put back from there.
    func discardLastSession() {
        guard stage != .running, let folder = lastSessionFolder else { return }
        do {
            try SessionStore.discard(folder, toTrash: true)
            prompt = "Session \(folder.lastPathComponent) was moved to the Trash."
            problem = nil
        } catch {
            problem = "The session could not be removed: \(error.localizedDescription)"
        }
        sessionOpen = 0
        sessionClosed = 0
        dataset = DatasetStats.scan(outputRoot)
        lastSessionFolder = SessionStore.latest(in: outputRoot)
    }

    private func runSession() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let sessionID = formatter.string(from: Date())

        let writer: SessionWriter
        do {
            writer = try SessionWriter(root: outputRoot, session: sessionID, condition: condition)
        } catch {
            problem = "The session folder could not be created: \(error.localizedDescription)"
            stage = .ready
            return
        }

        sessionOpen = 0
        sessionClosed = 0
        problem = nil
        prompt = "Listen to the voice..."
        await speaker.say("Starting. Follow my voice, and blink whenever you need to.")

        for (index, phase) in SessionScript.phases.enumerated() {
            if Task.isCancelled { break }
            phaseIndex = index
            currentLabel = phase.label
            prompt = phase.instruction

            phaseState = .listening
            await speaker.say(phase.instruction)
            if Task.isCancelled { break }

            phaseState = .settling
            try? await Task.sleep(nanoseconds: UInt64(SessionScript.settleSeconds * 1_000_000_000))
            if Task.isCancelled { break }

            phaseState = .recording
            withAnimation(.linear(duration: SessionScript.recordSeconds)) { recordProgress = 1 }
            pipeline.setRecording(FramePipeline.Recording(writer: writer, phaseIndex: index, phase: phase))
            try? await Task.sleep(nanoseconds: UInt64(SessionScript.recordSeconds * 1_000_000_000))
            pipeline.setRecording(nil)
            recordProgress = 0
            NSSound(named: "Tink")?.play()   // audible with eyes closed: "this pose is done"
        }

        pipeline.setRecording(nil)
        let stopped = Task.isCancelled
        phaseState = .idle
        currentLabel = nil
        recordProgress = 0
        lastSessionFolder = writer.folder
        dataset = DatasetStats.scan(outputRoot)

        if stopped {
            prompt = "Stopped. What was recorded so far is kept."
        } else {
            await speaker.say("Finished. You can open your eyes.")
            prompt = "Session saved: \(sessionOpen) open and \(sessionClosed) closed pictures."
        }
        stage = .ready
    }
}
