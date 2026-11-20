import SwiftUI
import AppKit
import BlinkCore

/// Where the program starts.
///
///     BlinkRecorder --out=<folder>     the recording window, sessions written to <folder>
///     BlinkRecorder --no-camera        the window alone, the camera left off
@main
enum Entry {
    static func main() {
        BlinkRecorderApp.main()
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
