import SwiftUI
import AppKit

/// Where the program starts.
///
///     BlinkRecorder --out=<folder>     the recording window
///     BlinkRecorder --selftest         checks the pipeline without the camera, then quits
///     BlinkRecorder --no-camera        the window alone, the camera left off
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        BlinkRecorderApp.main()
    }
}

enum Options {
    /// `--no-camera`: open the window without touching the camera (to check that the
    /// window itself works, without a permission question).
    static var noCamera: Bool { CommandLine.arguments.contains("--no-camera") }

    /// The folder the sessions are written to.
    static var outputRoot: URL {
        for argument in CommandLine.arguments where argument.hasPrefix("--out=") {
            return URL(fileURLWithPath: String(argument.dropFirst("--out=".count)), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/BlinkMonitor/data/raw", isDirectory: true)
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
