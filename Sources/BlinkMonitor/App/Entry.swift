import AppKit
import BlinkCore

/// Where the program starts.
///
///     BlinkMonitor                         the menu-bar app (its setup, when it has no model)
///       --model=<EyeNet.mlmodelc>          a Core ML model to use, whatever else there is
///       --sessions-dir=<folder>            where setup records its sessions, and trains from
///                                          (`make recorder` passes the project's data/raw)
///       --capture-dir=<folder>             where the Live View window saves its captures
///       --whole-frames-dir=<folder>        captures also keep the whole camera picture, and go
///                                          there instead (to replay the eye finding: make replay)
///       --open=<window>[,<window>]         open windows at launch: setup, live-view, history,
///                                          settings, blink-break, routine-timer (to look at
///                                          them; routine-timer also starts the timer)
///       --eye-search=whole-frame           find the face in the whole frame at every search, as
///                                          the first versions did (to compare what it costs)
///       --no-camera                        leave the camera off (to look at the windows)
///       --demo                             made-up eyes: no camera, no model (make demo)
///       --play-setup                       with --demo: the setup goes through itself on painted
///                                          eyes, with no click (its steps are in the log)
///     BlinkMonitor --snapshots=<folder>    render every screen to PNG with made-up data, then quit
///     BlinkMonitor --train --sessions-dir=<folder> --model-out=<folder>
///                                          train a model and quit: the app starts itself this
///                                          way during setup (see TrainingJob)
@main
enum Entry {
    @MainActor
    static func main() {
        // Started only to train: no window, no menu-bar item, nothing but the training.
        if LaunchArguments.has("train") {
            exit(TrainingRun.helper())
        }
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

    /// The demo: the whole app on made-up eyes, for trying it before setting it up.
    /// Asked for at launch, or built in: the app that `make demo` builds carries the key,
    /// so that opening it from the Finder is a demo too. (The setup's welcome page can
    /// also switch a running app to the demo and back: see `AppDelegate.switchTo`.)
    static var demo: Bool {
        LaunchArguments.has("demo") || Bundle.main.object(forInfoDictionaryKey: "BlinkMonitorDemo") as? Bool == true
    }

    /// Where setup records its sessions: the folder given at launch (`make recorder`
    /// passes the project's data/raw), else next to the app's own files.
    static var sessionsRoot: URL {
        LaunchArguments.folder("sessions-dir") ?? SessionStore.standardRoot
    }

    /// The sessions folder is the app's own, to delete from as Settings says. A folder
    /// named at launch is a developer's data: nothing in it is deleted for good.
    static var ownSessions: Bool { LaunchArguments.folder("sessions-dir") == nil }

    /// Where the Live View window saves its captures: the folder given at launch
    /// (`make monitor` passes the project's data/live), else next to the app's own files.
    static var captureRoot: URL {
        LaunchArguments.folder("capture-dir") ?? ownCaptureRoot
    }

    /// The captures folder among the app's own files. Versions before the record buttons
    /// were hidden saved there; Settings lists it and deletes it with the recordings.
    static var ownCaptureRoot: URL {
        HistoryStore.applicationFolder.appendingPathComponent("captures", isDirectory: true)
    }

    /// THE TOOLS OF WHOEVER WORKS ON THE APP: Live View's two record buttons and its
    /// "cost per frame" table. They show only when the app was started with a folder for
    /// captures (`make monitor` passes one). An ordinary user never sees a button that
    /// saves pictures of their eyes to a folder: Settings promises that deleting "removes
    /// every picture of your eyes", and that has to be true.
    static var developerTools: Bool {
        LaunchArguments.folder("capture-dir") != nil || wholeFrameRoot != nil
    }

    /// Set when captures must also keep the whole camera picture of every frame: the
    /// folder they go to. Never the default: such a capture is a film of a face, where an
    /// ordinary one is two small pictures of eyes. It is for working on the stage that
    /// finds the eyes (`CaptureReplay`), and is asked for at launch, by whoever does that.
    static var wholeFrameRoot: URL? { LaunchArguments.folder("whole-frames-dir") }

    /// How the eyes are found: the usual way, unless the old one is asked for at launch.
    /// The two can then be timed on the same Mac, the same day, in the same light.
    static var eyeSearch: EyeLocator.Strategy {
        LaunchArguments.value(of: "eye-search") == "whole-frame" ? .wholeFrame : EyeLocator.usual
    }

    static var snapshotFolder: URL? { LaunchArguments.folder("snapshots") }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Everything that exists around one `MonitorModel`. It is replaced as a whole when
    /// the app enters or leaves the demo: the demo is another model, with its own
    /// settings, its own history and made-up eyes.
    private struct Running {
        let model: MonitorModel
        let statusItem: StatusItemController
        let setup: SetupModel
        let windows: [String: WindowController]
        var welcome: WindowController?
        let isDemo: Bool
    }

    private var running: Running?
    /// Why the setup window is being opened (read when it opens).
    private var setupPurpose = SetupModel.Purpose.resume

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
            Log.app.notice("An older build of this app, or a copy on its disk image, is still running: it is asked to quit")
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

    /// What is set up once, whichever model runs, and then the first model.
    private func launch() {
        if Installation.isOnDiskImage { Log.app.notice("Running from a read-only disk: the panel says to drag the app to Applications") }
        NSApp.mainMenu = MainMenu.make(target: self, settings: #selector(showSettings))

        // Another copy that started and gave way asks this one to show itself.
        if let identifier = Bundle.main.bundleIdentifier {
            DistributedNotificationCenter.default().addObserver(
                forName: Installation.showPanelRequest(identifier: identifier), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showYourself() }
            }
        }

        // The app comes forward: what was refused may have been allowed meanwhile.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.running?.model.comeForward() }
        }

        // The screen sleeping or the session being locked: nobody to watch, camera off.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.running?.model.setAsleep(true) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.running?.model.setAsleep(false) }
            }
        }

        launch(demo: Options.demo)
        for name in Options.windowsToOpen where name != "routine-timer" {
            if name == "setup" { showSetup(.resume) } else { running?.windows[name]?.show() }
        }
        // The timer's window is opened by a timer starting, not by hand.
        if Options.windowsToOpen.contains("routine-timer"), let routines = running?.model.routines,
           let timed = routines.routines.first(where: { $0.sessionMinutes != nil }) {
            routines.startSession(timed.id)
        }
        if LaunchArguments.has("play-setup"), let running, running.isDemo {
            showSetup(.resume)
            Task { await running.setup.play() }
        }
    }

    // MARK: - One model and its windows

    /// Creates the model, its menu-bar item and its windows, and starts it.
    private func launch(demo: Bool) {
        let model = demo ? SampleData.demoModel() : MonitorModel(preferences: Preferences())
        let preferences = model.preferences

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

        // The setup. In the demo it runs on painted eyes and writes to a temporary folder.
        let parts = demo ? SampleData.demoSetupParts(monitor: model)
            : SetupModel.Parts(monitor: model, store: model.modelStore, sessionsRoot: Options.sessionsRoot,
                               ownSessions: Options.ownSessions)
        let setupModel = SetupModel(parts: parts)
        let setup = WindowController(title: "Blink Monitor - Setup", remembersPosition: false) { [weak self] in
            SetupView(model: setupModel, actions: SetupActions(
                // Offered where there is something to leave: not in the demo itself.
                tryDemo: demo ? nil : { self?.switchTo(demo: true) },
                openCameraSettings: Self.openCameraSettings,
                showFiles: { NSWorkspace.shared.activateFileViewerSelecting([parts.store.base]) },
                close: { self?.running?.windows["setup"]?.close() },
                // The window closing leaves nothing on screen, and the eye may be hidden
                // behind the notch: Done shows where the app lives from now on.
                done: {
                    self?.running?.windows["setup"]?.close()
                    self?.running?.statusItem.showPanel()
                },
                watchItCount: {
                    self?.running?.windows["setup"]?.close()
                    self?.running?.windows["live-view"]?.show()
                },
                openSettings: { self?.running?.windows["settings"]?.show() },
                openNotificationSettings: Self.openNotificationSettings))
        }
        // The window opening starts (or resumes) the setup; its closing stops whatever
        // was under way. What was finished is on disk, so nothing is lost.
        setup.onVisibilityChange = { [weak self] open in
            if open { setupModel.open(self?.setupPurpose ?? .resume) } else { setupModel.close() }
            // A DOCK ICON WHILE THE SETUP IS OPEN. An app with none has no entry under
            // Cmd-Tab either: one click on another app (System Settings, to allow the
            // camera) and the setup window was behind everything, with no way back that a
            // newcomer knows. The icon goes when the window closes.
            NSApp.setActivationPolicy(open ? .regular : .accessory)
            if open { NSApp.activate(ignoringOtherApps: true) }
        }

        // A routine's timer: starting it opens the window, its end closes it. Closing the
        // window by hand does NOT stop the timer (unlike the blink break): whoever is
        // under a mask must not lose the sound at the end to a stray click. Stop is a button.
        let routineTimer = WindowController(title: "Routine Timer") {
            RoutineSessionView(routines: model.routines, session: model.routines.session)
        }
        model.routines.session.onOpen = { routineTimer.show() }
        model.routines.session.onClose = { routineTimer.close() }

        let settingsState = SettingsState()
        let recordings = SettingsFiles(store: parts.store, sessionsRoot: parts.sessionsRoot, ownSessions: parts.ownSessions,
                                       capturesRoot: demo ? nil : Options.ownCaptureRoot)
        let settings = WindowController(title: "Blink Monitor - Settings") { [weak self] in
            SettingsView(model: model, preferences: preferences, history: model.history, reminders: model.reminders,
                         loginItem: model.loginItem, state: settingsState, files: recordings,
                         actions: SettingsActions(startBlinkBreak: { blinkBreak.show() },
                                                  openLiveView: { liveView.show() },
                                                  openSetup: { self?.showSetup($0) },
                                                  closeSetup: { setup.close() }))
        }
        settings.onVisibilityChange = { open in
            if open { settingsState.refresh(recordings) } else { settingsState.reset() }
        }

        // In a demo entered from the setup window, the way back is offered. The app that
        // `make demo` builds is a demo for good: its banner points at the real one.
        let leaveDemo: (() -> Void)? = demo && !Options.demo ? { [weak self] in self?.switchTo(demo: false) } : nil
        let statusItem = StatusItemController(model: model, actions: PanelActions(
            startBlinkBreak: { blinkBreak.show() }, openHistory: { history.show() }, openSettings: { settings.show() },
            openLiveView: { liveView.show() }, openCameraSettings: Self.openCameraSettings,
            openSetup: { [weak self] in self?.showSetup(.resume) }, leaveDemo: leaveDemo, quit: { NSApp.terminate(nil) }))

        var running = Running(model: model, statusItem: statusItem, setup: setupModel,
                              windows: ["history": history, "live-view": liveView, "blink-break": blinkBreak,
                                        "settings": settings, "setup": setup, "routine-timer": routineTimer],
                              welcome: nil, isDemo: demo)

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
        } else if ModelSource.resolve(store: model.modelStore) == .none {
            // No model of your eyes yet: the first thing to do is to make one. The camera
            // is not touched until the setup's first page has said why.
            Task { await model.start() }
            if !Options.noCamera {
                DispatchQueue.main.async { [weak self] in
                    // Six minutes of setup in a copy that goes away with its disk: ask first.
                    if Installation.isOnDiskImage, !Self.continueFromDiskImage() { return NSApp.terminate(nil) }
                    self?.showSetup(.resume)
                }
            }
        } else if preferences.welcomed || Options.noCamera {
            Task { await model.start() }
        } else {
            // A model is built in: say what the app does BEFORE macOS asks for the camera.
            let welcome = WindowController(title: "Welcome to Blink Monitor", remembersPosition: false) { [weak self] in
                WelcomeView { self?.running?.welcome?.close() }      // Start = close the window
            }
            // Closing the window IS starting, whichever way it is closed: by the Start
            // button or by the red one. (The first version only started on the button,
            // and a window closed by the red one left the app waiting for the whole run.)
            welcome.onVisibilityChange = { open in
                guard !open else { return }
                preferences.welcomed = true
                _ = startAndShow()
            }
            running.welcome = welcome
            welcome.show()
        }
        self.running = running
    }

    /// Opens the setup window for a purpose (go on, add a session, take the test again).
    private func showSetup(_ purpose: SetupModel.Purpose) {
        guard let running else { return }
        setupPurpose = purpose
        // Already open, and asked for something else: start over from the new purpose.
        if purpose != .resume {
            running.setup.close()
            running.setup.open(purpose)
        }
        running.windows["setup"]?.show()
    }

    /// Enters or leaves the demo while the app runs: everything built around the model
    /// is taken down, and built again around the other one.
    private func switchTo(demo: Bool) {
        if let running {
            running.setup.close()
            for window in running.windows.values { window.onVisibilityChange = nil; window.close() }
            running.welcome?.onVisibilityChange = nil
            running.welcome?.close()
            running.statusItem.remove()
            running.model.shutDown()
            // The setup window was closed without its handler: its Dock icon goes with it.
            NSApp.setActivationPolicy(.accessory)
        }
        running = nil
        launch(demo: demo)
        // Back from the demo: to the setup, where the demo was offered.
        if !demo { showSetup(.resume) }
    }

    @objc private func showSettings() {
        running?.windows["settings"]?.show()
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
            running?.statusItem.showPanel()
        }
        Log.app.notice("Opened again while running: shown")
    }

    /// Asked before the setup when the app was opened inside its disk image, without
    /// being dragged to Applications. The panel says so too, but nobody has opened the
    /// panel yet, and the setup would take six minutes in the wrong place. True to go on.
    private static func continueFromDiskImage() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Blink Monitor is running from its disk image"
        alert.informativeText = """
            Move it to Applications first: quit, drag Blink Monitor onto the Applications \
            folder in the disk image's window, and open it from there.

            It works from here, for a look. But this copy goes away when the disk image \
            is ejected, and it cannot start at login.
            """
        alert.addButton(withTitle: "Quit")                  // the default: Return quits
        alert.addButton(withTitle: "Continue Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// System Settings, on the page of this app's notifications.
    static func openNotificationSettings() {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)") {
            NSWorkspace.shared.open(url)
        }
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
