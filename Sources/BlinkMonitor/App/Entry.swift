import AppKit
import BlinkCore

/// Where the program starts.
///
///     BlinkMonitor                         the menu-bar app
///       --model=<EyeNet.mlmodelc>          another model than the one inside the app
///       --capture-dir=<folder>             where the diagnostics window saves its captures
///       --diagnostics                      open the diagnostics window at launch
///       --no-camera                        leave the camera off (to look at the windows)
///     BlinkMonitor --snapshots=<folder>    render every screen to PNG with made-up data, then quit
@main
enum Entry {
    @MainActor
    static func main() {
        if let folder = Options.snapshotFolder {
            exit(Snapshots.render(to: folder) ? 0 : 1)
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
    static var openDiagnostics: Bool { CommandLine.arguments.contains("--diagnostics") }

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

    /// Where the diagnostics window saves its captures: the folder given at launch
    /// (`make monitor` passes the project's data/live), else next to the app's own files.
    static var captureRoot: URL {
        if let path = value(of: "capture-dir") { return URL(fileURLWithPath: path, isDirectory: true) }
        return HistoryStore.applicationFolder.appendingPathComponent("captures", isDirectory: true)
    }

    static var snapshotFolder: URL? {
        value(of: "snapshots").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: MonitorModel?
    private var statusItem: StatusItemController?
    private var windows: [WindowController] = []

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
        self.model = model

        let history = WindowController(title: "Blink Monitor - History") {
            HistoryView(history: model.history, reminders: model.reminders)
        }
        let diagnostics = WindowController(title: "Blink Monitor - Diagnostics", resizable: true) {
            DiagnosticsView(model: model, captures: model.captures)
        }
        // The camera picture and the curve are only prepared while this window shows them.
        diagnostics.onVisibilityChange = { open in model.setDiagnosticsOpen(open) }
        windows = [history, diagnostics]

        var actions = PanelActions()
        actions.openHistory = { history.show() }
        actions.openDiagnostics = { diagnostics.show() }
        actions.quit = { NSApp.terminate(nil) }
        statusItem = StatusItemController(model: model, actions: actions)

        // The screen sleeping or the session being locked: nobody to watch, camera off.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { model.setAsleep(true) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { model.setAsleep(false) }
            }
        }

        // The first time, say what the app does BEFORE macOS asks for the camera.
        let settings = Settings()
        if settings.welcomed || Options.noCamera {
            Task { await model.start() }
        } else {
            let welcome = WindowController(title: "Welcome to Blink Monitor") { [weak self] in
                WelcomeView { self?.windows.last?.close() }      // Start = close the window
            }
            // Closing the window IS starting, whichever way it is closed: by the Start
            // button or by the red one. (The first version only started on the button,
            // and a window closed by the red one left the app waiting for the whole run.)
            welcome.onVisibilityChange = { open in
                guard !open else { return }
                settings.welcomed = true
                Task { await model.start() }
            }
            windows.append(welcome)
            welcome.show()
        }
        if Options.openDiagnostics { diagnostics.show() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
