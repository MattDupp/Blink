import AppKit
import BlinkCore

/// Where the program starts.
///
///     BlinkMonitor                         the menu-bar app
///       --model=<EyeNet.mlmodelc>          another model than the one inside the app
///       --capture-dir=<folder>             where the Live View window saves its captures
///       --open=<window>[,<window>]         open windows at launch: live-view, history, settings,
///                                          blink-break (to look at them, or to check they open)
///       --no-camera                        leave the camera off (to look at the windows)
///       --demo                             made-up eyes: no camera, no model (make demo).
///                                          Also what a copy with no model inside does.
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
    /// The windows to open at launch, by name.
    static var windowsToOpen: [String] {
        (LaunchArguments.value(of: "open") ?? "").split(separator: ",").map(String.init)
    }

    /// The demo: the whole app on made-up eyes, for trying it before training a model.
    /// Asked for at launch, or built in: the app that `make demo` builds carries the key,
    /// so that opening it from the Finder is a demo too.
    ///
    /// And it is what an app with NO MODEL does. The app that the disk image installs
    /// (`make dmg`) has none: a model is made from pictures of its owner's eyes and is
    /// not handed out with the app. That copy has nothing to count real blinks with, so
    /// it shows what the app does, says that the blinks are made up, and says how to get
    /// a model. A model that was asked for by name and is not there stays an error.
    static var demo: Bool {
        LaunchArguments.has("demo") || Bundle.main.object(forInfoDictionaryKey: "BlinkMonitorDemo") as? Bool == true
            || (LaunchArguments.value(of: "model") == nil && !FileManager.default.fileExists(atPath: modelURL.path))
    }

    /// The compiled model: given on the command line, else the copy inside the app
    /// (BlinkMonitor.app/Contents/Resources/EyeNet.mlmodelc, put there by the build script).
    static var modelURL: URL {
        if let folder = LaunchArguments.folder("model") { return folder }
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("EyeNet.mlmodelc", isDirectory: true)
    }

    /// Where the Live View window saves its captures: the folder given at launch
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
    private var settings: WindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy only: two would mean two menu-bar items and the camera read twice.
        // Which of the two stays is decided in `Installation.start`.
        guard !Options.noCamera, let identifier = Bundle.main.bundleIdentifier else { return launch() }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0 != NSRunningApplication.current }
        switch Installation.start(own: Bundle.main.bundleURL, running: others.map(\.bundleURL)) {
        case .alone:
            launch()
        case .yielding:
            // The first version quit without a word, and opening the app a second time
            // looked like an app that does not open.
            Log.app.notice("Another copy is running: it is asked to show its panel, and this one quits")
            DistributedNotificationCenter.default().postNotificationName(
                Installation.showPanelRequest(identifier: identifier), object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        case .replacing:
            Log.app.notice("An older build of this app is still running: it is asked to quit")
            others.forEach { $0.terminate() }
            launch(after: others)
        }
    }

    /// Starts once the copies that were asked to quit have quit. One that has not after
    /// five seconds is made to.
    private func launch(after others: [NSRunningApplication], attemptsLeft: Int = 25) {
        let remaining = others.filter { !$0.isTerminated }
        if remaining.isEmpty { return launch() }
        if attemptsLeft == 0 { remaining.forEach { $0.forceTerminate() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.launch(after: remaining, attemptsLeft: max(attemptsLeft - 1, 0))
        }
    }

    private func launch() {
        let demo = Options.demo
        if demo && !LaunchArguments.has("demo") { Log.app.notice("No model in this copy: running as the demo") }
        if Installation.isOnDiskImage { Log.app.notice("Running from a read-only disk: the panel says to drag the app to Applications") }

        let model = demo ? SampleData.demoModel() : MonitorModel(preferences: Preferences())
        let preferences = model.preferences
        self.model = model

        let historyState = HistoryState()
        let history = WindowController(title: "Blink Monitor - History") {
            HistoryView(history: model.history, preferences: preferences, state: historyState)
        }
        history.onVisibilityChange = { open in if open { historyState.selectedDay = nil } }   // opens on today
        let liveView = WindowController(title: "Blink Monitor - Live View", resizable: true) {
            LiveView(model: model, captures: model.captures)
        }
        // The camera picture and the curve are only prepared while this window shows them.
        liveView.onVisibilityChange = { open in model.setLiveViewOpen(open) }

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
                                                  openLiveView: { liveView.show() }))
        }
        settings.onVisibilityChange = { open in if !open { settingsState.reset() } }
        self.settings = settings
        windows = [history, liveView, blinkBreak, settings]

        let statusItem = StatusItemController(model: model, actions: PanelActions(
            startBlinkBreak: { blinkBreak.show() }, openHistory: { history.show() }, openSettings: { settings.show() },
            openLiveView: { liveView.show() }, openCameraSettings: Self.openCameraSettings, openGuide: Self.openGuide,
            quit: { NSApp.terminate(nil) }))
        self.statusItem = statusItem
        NSApp.mainMenu = MainMenu.make(target: self, settings: #selector(showSettings))

        // Another copy that started and gave way asks this one to show itself.
        if let identifier = Bundle.main.bundleIdentifier {
            DistributedNotificationCenter.default().addObserver(
                forName: Installation.showPanelRequest(identifier: identifier), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showYourself() }
            }
        }

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

        // An app with no window has to show where it lives: the first time (and in the
        // demo), the panel opens by itself under its menu-bar item once things run.
        let startAndShow = {
            Task {
                await model.start()
                statusItem.showPanel()
            }
        }
        if demo {
            _ = startAndShow()
        } else if preferences.welcomed || Options.noCamera {
            Task { await model.start() }
        } else {
            // The first time, say what the app does BEFORE macOS asks for the camera.
            let welcome = WindowController(title: "Welcome to Blink Monitor", remembersPosition: false) { [weak self] in
                WelcomeView { self?.windows.last?.close() }      // Start = close the window
            }
            // Closing the window IS starting, whichever way it is closed: by the Start
            // button or by the red one. (The first version only started on the button,
            // and a window closed by the red one left the app waiting for the whole run.)
            welcome.onVisibilityChange = { open in
                guard !open else { return }
                preferences.welcomed = true
                _ = startAndShow()
            }
            windows.append(welcome)
            welcome.show()
        }
        let byName = ["live-view": liveView, "history": history, "settings": settings, "blink-break": blinkBreak]
        for name in Options.windowsToOpen { byName[name]?.show() }
    }

    @objc private func showSettings() {
        settings?.show()
    }

    /// The app was opened while it is already running: from Finder, from Spotlight, or by
    /// a second copy that gave way. An ordinary app answers by bringing its window
    /// forward. This one has none, so it opens its panel: otherwise nothing at all would
    /// happen, and the eye may be hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showYourself()
        return false
    }

    private func showYourself() {
        // `hasVisibleWindows` counts the menu-bar item's own window: look for a real one.
        if NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            statusItem?.showPanel()
        }
        Log.app.notice("Opened again while running: shown")
    }

    /// The page that says how to train a model, in the browser.
    private static func openGuide() {
        if let url = Installation.guide { NSWorkspace.shared.open(url) }
    }

    /// System Settings, on the page where the camera is allowed app by app.
    private static func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
