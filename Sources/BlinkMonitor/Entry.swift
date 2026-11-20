import AppKit

/// Where the program starts.
///
///     BlinkMonitor [--capture-dir=<folder>] [--live]   the menu-bar app (--live: open the live view too)
///     BlinkMonitor --selftest --model=<EyeNet.mlmodelc> --reference=<eyenet_reference.json>
///                                                      checks the logic and the model, then quits
///     BlinkMonitor --no-camera                         the menu-bar app with the camera left off
@main
enum Entry {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }

        // A MENU-BAR APP is an ordinary app with three differences:
        //   1. it has no Dock icon and no main window ("accessory" - and LSUIElement in
        //      its Info.plist, so the Dock icon does not even flash at launch);
        //   2. it puts an item in the menu bar (StatusItemController);
        //   3. closing its windows does not quit it.
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

enum Options {
    static var noCamera: Bool { CommandLine.arguments.contains("--no-camera") }
    static var openLiveView: Bool { CommandLine.arguments.contains("--live") }

    private static func value(of name: String) -> String? {
        for argument in CommandLine.arguments where argument.hasPrefix("--\(name)=") {
            return String(argument.dropFirst(name.count + 3))
        }
        return nil
    }

    /// The compiled model: given on the command line, else the copy inside the app
    /// (BlinkMonitor.app/Contents/Resources/EyeNet.mlmodelc, put there by the build script).
    static var modelURL: URL {
        if let path = value(of: "model") { return URL(fileURLWithPath: path, isDirectory: true) }
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("EyeNet.mlmodelc", isDirectory: true)
    }

    /// Where "Record..." writes its captures (the build script passes data/live).
    static var captureRoot: URL {
        if let path = value(of: "capture-dir") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/BlinkMonitor/data/live", isDirectory: true)
    }

    /// The reference answers written by training/convert.py (self-test only).
    static var referenceURL: URL? {
        value(of: "reference").map { URL(fileURLWithPath: $0) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: MonitorModel?
    private var statusItem: StatusItemController?
    private var liveWindow: LiveWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy only: two would mean two menu-bar items and the camera read twice.
        if !Options.noCamera, let identifier = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { $0 != NSRunningApplication.current }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        let model = MonitorModel()
        let liveWindow = LiveWindowController(model: model)
        self.model = model
        self.liveWindow = liveWindow
        statusItem = StatusItemController(model: model) { liveWindow.show() }

        // The screen sleeping or the session being locked: nobody to watch, camera off.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in model.setAsleep(true) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in model.setAsleep(false) }
            }
        }

        Task { await model.start() }
        if Options.openLiveView { liveWindow.show() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
