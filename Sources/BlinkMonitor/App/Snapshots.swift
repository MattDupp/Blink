import AppKit
import SwiftUI
import BlinkCore
import BlinkUI

/// Renders every screen of the app to a PNG, with made-up data:
///
///     BlinkMonitor --snapshots=<folder>          (or: make snapshots)
///
/// The drawing is `ScreenRenderer`; the made-up data is `SampleData`. The app's own types know nothing about screenshots: they are simply
/// started from a state instead of from the camera.
@MainActor
enum Snapshots {

    static func render(to folder: URL) -> Bool {
        // A fixed moment (a Friday afternoon), so the pictures do not change from day to day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 16, minute: 42, second: 38)) ?? Date()
        return ScreenRenderer.render(to: folder) { screens(now: now) }
    }

    /// Every screen, in every state worth looking at.
    private static func screens(now: Date) -> [(String, AnyView)] {
        func panel(_ scene: SampleData.Scene, onDiskImage: Bool = false, configure: (PanelState) -> Void = { _ in }) -> AnyView {
            let model = SampleData.model(now: now, scene: scene)
            let state = PanelState()
            configure(state)
            return AnyView(MenuPanelView(model: model, history: model.history, reminders: model.reminders,
                                         preferences: model.preferences, state: state, moment: Moment(frozen: now),
                                         onDiskImage: onDiskImage, actions: PanelActions()))
        }
        func settings(_ tab: SettingsState.Tab, scene: SampleData.Scene = .watching,
                      configure: (SettingsState, MonitorModel) -> Void = { _, _ in }) -> AnyView {
            let model = SampleData.model(now: now, scene: scene)
            let state = SettingsState()
            state.tab = tab
            // (The pictures have no camera to ask: one is stated.)
            state.cameras = [CameraOption(id: "own", name: "FaceTime HD Camera", builtIn: true)]
            configure(state, model)
            // A folder that does not exist: the screenshots state what is on disk instead.
            let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("blink-monitor-sample-setup", isDirectory: true)
            return AnyView(SettingsView(model: model, preferences: model.preferences, history: model.history,
                                        reminders: model.reminders, loginItem: model.loginItem, state: state,
                                        moment: Moment(frozen: now),
                                        files: SettingsFiles(store: ModelStore(base: nowhere), sessionsRoot: nowhere),
                                        // (A closure that does nothing: the card is drawn, and a picture cannot press it.)
                                        actions: SettingsActions(deleteEverythingAndQuit: {})))
        }
        func setup(_ scene: SampleData.SetupScene) -> AnyView {
            let model = SampleData.setup(scene, now: now)
            // The demo is not offered from inside the demo.
            return AnyView(SetupView(model: model, cameraNote: "The camera picture is left out of screenshots.",
                                     actions: SetupActions(tryDemo: model.isDemo ? nil : {})))
        }
        let recorded = SettingsState.OnDisk(sessions: 2, pictures: 1912, megabytes: 19)
        func history(_ scene: SampleData.Scene, daysBack: Int = 0) -> AnyView {
            let model = SampleData.model(now: now, scene: scene)
            let state = HistoryState()
            if daysBack > 0 {
                state.selectedDay = Calendar.current.date(byAdding: .day, value: -daysBack, to: Calendar.current.startOfDay(for: now))
            }
            return AnyView(HistoryView(history: model.history, preferences: model.preferences, state: state, moment: Moment(frozen: now)))
        }
        func blinkBreak(_ scene: SampleData.Scene) -> AnyView {
            let model = SampleData.model(now: now, scene: scene)
            return AnyView(BlinkBreakView(model: model, blinkBreak: model.blinkBreak, moment: Moment(frozen: now)))
        }
        /// The panel with the built-in routine switched on, on a made-up day.
        func routinePanel(_ scene: SampleData.RoutineScene) -> AnyView {
            let model = SampleData.model(now: now, scene: .watching)
            SampleData.routines(in: model, now: now, scene: scene)
            return AnyView(MenuPanelView(model: model, history: model.history, reminders: model.reminders,
                                         preferences: model.preferences, state: PanelState(), moment: Moment(frozen: now),
                                         actions: PanelActions()))
        }
        /// The panel with the routine counted by the week switched on, in a made-up week.
        func weekPanel(_ scene: SampleData.WeekScene, withDrops: Bool = false, open: Bool = false) -> AnyView {
            let model = SampleData.model(now: now, scene: scene == .timer ? .paused : .watching)
            if withDrops { SampleData.routines(in: model, now: now, scene: .kept) }
            SampleData.week(in: model, now: now, scene: scene)
            if open { model.routines.openWeeks = Set(model.routines.routines.map(\.id)) }
            return AnyView(MenuPanelView(model: model, history: model.history, reminders: model.reminders,
                                         preferences: model.preferences, state: PanelState(), moment: Moment(frozen: now),
                                         actions: PanelActions()))
        }
        /// The panel with routines the user made.
        func ownPanel(_ scene: SampleData.OwnScene) -> AnyView {
            let model = SampleData.model(now: now, scene: .watching)
            SampleData.own(in: model, now: now, scene: scene)
            return AnyView(MenuPanelView(model: model, history: model.history, reminders: model.reminders,
                                         preferences: model.preferences, state: PanelState(), moment: Moment(frozen: now),
                                         actions: PanelActions()))
        }
        func routineTimer(_ scene: SampleData.WeekScene) -> AnyView {
            let model = SampleData.model(now: now, scene: .watching)
            SampleData.week(in: model, now: now, scene: scene)
            return AnyView(RoutineSessionView(routines: model.routines, session: model.routines.session,
                                              moment: Moment(frozen: now)))
        }
        let watching = SampleData.model(now: now, scene: .watching)

        return [
            ("panel", panel(.watching)),
            ("panel-low", panel(.low)),
            ("panel-paused", panel(.paused)),
            ("panel-pause-choices", panel(.watching) { $0.choosingPause = true }),
            ("panel-learning", panel(.learning) { $0.hoveredMinute = 14 }),
            ("panel-first-minute", panel(.firstMinute)),
            ("panel-no-picture", panel(.noPicture)),
            ("panel-own-rate", panel(.ownRate)),
            ("panel-quiet", panel(.quiet)),
            ("panel-no-face", panel(.noFace)),
            ("panel-camera-refused", panel(.cameraRefused)),
            ("panel-problem", panel(.problem)),
            ("panel-demo", panel(.demo)),
            ("panel-needs-setup", panel(.needsSetup)),
            ("panel-setting-up", panel(.settingUp)),
            ("setup-welcome", setup(.welcome)),
            ("setup-welcome-demo", setup(.demoWelcome)),
            ("setup-welcome-back", setup(.welcomeBack)),
            ("setup-camera", setup(.camera)),
            ("setup-camera-no-face", setup(.cameraNoFace)),
            ("setup-camera-dark", setup(.cameraDark)),
            ("setup-camera-refused", setup(.cameraRefused)),
            ("setup-record", setup(.recordFirst)),
            ("setup-record-muted", setup(.recordMuted)),
            ("setup-record-session", setup(.recording)),
            ("setup-record-pose-ended", setup(.poseEnded)),
            ("setup-record-short", setup(.recordShort)),
            ("setup-record-next", setup(.recordNext)),
            ("setup-record-enough", setup(.recordEnough)),
            ("setup-train", setup(.training)),
            ("setup-train-failed", setup(.trainingFailed)),
            ("setup-train-failed-again", setup(.trainingFailedAgain)),
            ("setup-trained", setup(.trained)),
            ("setup-test", setup(.testReady)),
            ("setup-test-running", setup(.testRunning)),
            ("setup-test-passed", setup(.testPassed)),
            ("setup-test-failed", setup(.testFailed)),
            ("setup-done", setup(.done)),
            // Opened in the installer's window, without dragging it to Applications first.
            ("panel-demo-disk-image", panel(.demo, onDiskImage: true)),
            ("panel-looking-away", panel(.lookingAway)),
            ("panel-long-break", panel(.longBreak)),
            ("history", history(.watching)),
            ("history-empty", history(.firstMinute)),
            ("history-day", history(.low, daysBack: 1)),
            ("settings-general", settings(.general)),
            ("settings-reminders", settings(.reminders)),
            ("settings-reminders-learning", settings(.reminders, scene: .learning)),
            ("settings-reminders-measured", settings(.reminders, scene: .low) { state, model in
                // "Measure Again" has just been pressed, and the result is lower.
                state.measurement = Baseline.proposal(current: model.preferences.reference, records: model.history.minutes,
                                                      now: now).map { .proposed($0) }
            }),
            ("settings-reminders-limit-above", settings(.reminders) { _, model in
                // A floor above the user's own usual rate: the app says what will happen.
                model.preferences.floor = 16
            }),
            // A usual rate under, and above, what studies report at a screen: the marker
            // sits outside the bar, and nothing takes a colour.
            ("settings-reminders-reference-under", settings(.reminders) { _, model in
                model.preferences.reference = Reference(rate: 0.9, measuredOn: now.addingTimeInterval(-17 * 86_400), minutes: 214)
            }),
            ("settings-reminders-reference-above", settings(.reminders) { _, model in
                model.preferences.reference = Reference(rate: 21.3, measuredOn: now.addingTimeInterval(-17 * 86_400), minutes: 214)
            }),
            ("settings-breaks", settings(.breaks, scene: .learning)),
            ("settings-model", settings(.model) { state, _ in (state.onDisk, state.onDiskIsStated) = (recorded, true) }),
            ("settings-model-none", settings(.model, scene: .needsSetup)),
            ("settings-breaks-long", settings(.breaks, scene: .lookingAway)),
            ("settings-breaks-off", settings(.breaks)),
            ("settings-data", settings(.data)),
            // A 13-inch screen with a large Dock: the tab scrolls under the tab bar.
            ("settings-routines-small-screen", AnyView(settings(.routines) { _, model in
                SampleData.own(in: model, now: now, scene: .many)
            }.environment(\.screenRoom, 700))),
            ("settings-reminders-small-screen", AnyView(settings(.reminders).environment(\.screenRoom, 700))),
            ("history-small-screen", AnyView(history(.watching).environment(\.screenRoom, 700))),
            ("panel-small-screen", AnyView(routinePanel(.waiting).environment(\.screenRoom, 700))),
            ("settings-breaks-notifications-off", settings(.breaks, scene: .notificationsOff)),
            // A test reminder has nothing to show: its button is the way to allow them.
            ("settings-routines-notifications-off", settings(.routines, scene: .notificationsOff) { _, model in
                model.routines.openCard = model.routines.routines.first { $0.isBuiltIn }?.id
            }),
            ("settings-data-captures", settings(.data) { state, _ in
                var disk = recorded
                (disk.captures, disk.captureMegabytes) = (3, 41)
                (state.onDisk, state.onDiskIsStated) = (disk, true)
            }),
            ("settings-sources", settings(.sources)),
            // The list scrolls in the window: here it is whole, to be read.
            ("sources-list", AnyView(SourcesList().frame(width: 480))),
            ("panel-routine", routinePanel(.kept)),
            ("panel-routine-waiting", routinePanel(.waiting)),
            ("panel-routine-later", routinePanel(.putOff)),
            ("settings-routines", settings(.routines)),
            ("settings-routines-on", settings(.routines) { _, model in
                SampleData.routines(in: model, now: now, scene: .kept)
                model.routines.openCard = Routine.eyeDrops.id
            }),
            ("panel-week", weekPanel(.toCome)),
            ("panel-week-open", weekPanel(.toCome, open: true)),
            ("panel-week-waiting", weekPanel(.waiting)),
            ("panel-week-reached", weekPanel(.reached)),
            ("panel-week-timer", weekPanel(.timer)),
            ("panel-week-with-times", weekPanel(.toCome, withDrops: true)),
            ("settings-routines-week", settings(.routines) { _, model in
                SampleData.week(in: model, now: now, scene: .toCome)
                model.routines.openCard = Routine.heatedMask.id
            }),
            ("panel-own", ownPanel(.counting)),
            ("panel-own-waiting", ownPanel(.waiting)),
            ("panel-many", ownPanel(.many)),
            ("panel-many-all", ownPanel(.manyShown)),
            ("panel-many-quiet", ownPanel(.quiet)),
            ("settings-routines-own", settings(.routines) { _, model in
                SampleData.own(in: model, now: now, scene: .counting)
                model.routines.openCard = model.routines.routines.last { !$0.isBuiltIn }?.id
            }),
            ("settings-routines-many", settings(.routines) { _, model in
                SampleData.own(in: model, now: now, scene: .many)
            }),
            ("routine-timer", routineTimer(.timer)),
            ("routine-timer-done", routineTimer(.timerDone)),
            ("blink-break", blinkBreak(.blinkBreak(count: 6))),
            ("blink-break-done", blinkBreak(.blinkBreak(count: 10))),
            ("welcome", AnyView(WelcomeView(start: {}))),
            ("live-view", AnyView(LiveView(model: watching, captures: watching.captures, developerTools: false))),
            // As whoever works on the app sees it (started with a folder for captures).
            ("live-view-developer", AnyView(LiveView(model: watching, captures: watching.captures, developerTools: true))),
        ]
    }
}
