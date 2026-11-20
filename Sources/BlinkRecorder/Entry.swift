import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

/// Where the program starts.
///
///     BlinkRecorder --out=<folder>     the recording window, sessions written to <folder>
///     BlinkRecorder --no-camera        the window alone, the camera left off
///     BlinkRecorder --snapshots=<dir>  render the window to PNG with made-up data, then quit
@main
enum Entry {
    @MainActor
    static func main() {
        if let folder = LaunchArguments.folder("snapshots") {
            exit(ScreenRenderer.render(to: folder, screens: Snapshots.screens) ? 0 : 1)
        }
        BlinkRecorderApp.main()
    }
}

/// The recorder's window in the states worth a picture, with made-up numbers and no camera.
@MainActor
enum Snapshots {

    static func screens() -> [(name: String, view: AnyView)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blink-recorder-screens", isDirectory: true)

        let first = RecorderModel(outputRoot: root, lifecycle: .running)
        first.prompt = "Check that the two green squares sit on your eyes, then start a session."
        first.faceFound = true
        first.cropSide = 176

        let recording = RecorderModel(outputRoot: root, lifecycle: .running, sessionRunning: true)
        recording.dataset = DatasetStats(sessions: 2, open: 912, closed: 884)
        recording.phaseIndex = 4
        recording.phaseState = .recording
        recording.currentLabel = SessionScript.phases[4].label
        recording.prompt = SessionScript.phases[4].instruction
        recording.recordProgress = 0.6
        recording.faceFound = true
        recording.cropSide = 176
        recording.sessionOpen = 118
        recording.sessionClosed = 116

        let enough = RecorderModel(outputRoot: root, lifecycle: .running)
        enough.dataset = DatasetStats(sessions: 5, open: 2290, closed: 2206)
        enough.prompt = "Session saved: 462 open and 448 closed pictures."
        enough.faceFound = true
        enough.cropSide = 176
        enough.sessionOpen = 462
        enough.sessionClosed = 448

        return [("recorder", first), ("recorder-session", recording), ("recorder-done", enough)].map { name, model in
            (name, AnyView(RecorderView(model: model, cameraNote: "The camera picture is left out of screenshots.")))
        }
    }
}

enum Options {
    /// `--no-camera`: open the window without touching the camera (to check that the
    /// window itself works, without a permission question).
    static var noCamera: Bool { LaunchArguments.has("no-camera") }

    /// The folder the sessions are written to.
    static var outputRoot: URL {
        if let folder = LaunchArguments.folder("out") { return folder }
        // No folder given: next to the app's other files, never a path of one machine.
        return HistoryStore.applicationFolder.appendingPathComponent("recordings", isDirectory: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct BlinkRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderModel(outputRoot: Options.outputRoot)

    var body: some Scene {
        WindowGroup("Blink Recorder") {
            RecorderView(model: model)
        }
    }
}
