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
    static var noCamera: Bool { LaunchArguments.has("no-camera") }
    static var openDiagnostics: Bool { LaunchArguments.has("diagnostics") }

    /// The compiled model: given on the command line, else the copy inside the app
    /// (BlinkMonitor.app/Contents/Resources/EyeNet.mlmodelc, put there by the build script).
    static var modelURL: URL {
        if let folder = LaunchArguments.folder("model") { return folder }
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("EyeNet.mlmodelc", isDirectory: true)
    }

    /// Where the diagnostics window saves its captures: the folder given at launch
    /// (`make monitor` passes the project's data/live), else next to the app's own files.
    static var captureRoot: URL {
        if let folder = LaunchArguments.folder("capture-dir") { return folder }
        return HistoryStore.applicationFolder.appendingPathComponent("captures", isDirectory: true)
    }

    static var snapshotFolder: URL? { LaunchArguments.folder("snapshots") }
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

        let preferences = Preferences()
        let model = MonitorModel(preferences: preferences)
        self.model = model

        let historyState = HistoryState()
        let history = WindowController(title: "Blink Monitor - History") {
            HistoryView(history: model.history, preferences: preferences, state: historyState)
        }
        history.onVisibilityChange = { open in if open { historyState.selectedDay = nil } }   // opens on today
        let diagnostics = WindowController(title: "Blink Monitor - Diagnostics", resizable: true) {
            DiagnosticsView(model: model, captures: model.captures)
        }
        // The camera picture and the curve are only prepared while this window shows them.
        diagnostics.onVisibilityChange = { open in model.setDiagnosticsOpen(open) }

        // The blink break: its window opening starts the exercise, its closing ends it,
        // and the exercise ending closes the window.
        let blinkBreak = WindowController(title: "Blink Break") {
            BlinkBreakView(model: model, blinkBreak: model.blinkBreak)
        }
        blinkBreak.onVisibilityChange = { open in
            if open { model.blinkBreak.start() } else { model.blinkBreak.stop() }
        }
        model.blinkBreak.onFinished = { blinkBreak.close() }
        model.reminders.onBlinkBreak = { blinkBreak.show() }      // the reminder banner's button

        let settingsState = SettingsState()
        let settings = WindowController(title: "Blink Monitor - Settings") {
            SettingsView(model: model, preferences: preferences, history: model.history, reminders: model.reminders,
                         loginItem: model.loginItem, state: settingsState,
                         actions: SettingsActions(startBlinkBreak: { blinkBreak.show() },
                                                  openDiagnostics: { diagnostics.show() }))
        }
        settings.onVisibilityChange = { open in if !open { settingsState.reset() } }
        windows = [history, diagnostics, blinkBreak, settings]

        statusItem = StatusItemController(model: model, actions: PanelActions(
            startBlinkBreak: { blinkBreak.show() }, openHistory: { history.show() }, openSettings: { settings.show() },
            openDiagnostics: { diagnostics.show() }, quit: { NSApp.terminate(nil) }))

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
        if preferences.welcomed || Options.noCamera {
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
                preferences.welcomed = true
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
