import AppKit
import SwiftUI
import BlinkCore
import BlinkUI

/// Renders every screen of the app to a PNG, with made-up data:
///
///     BlinkMonitor --snapshots=<folder>          (or: make snapshots)
///
/// The drawing is `ScreenRenderer` (shared with the recorder); the made-up data is
/// `SampleData`. The app's own types know nothing about screenshots: they are simply
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
        func panel(_ scene: SampleData.Scene, configure: (PanelState) -> Void = { _ in }) -> AnyView {
            let model = SampleData.model(now: now, scene: scene)
            let state = PanelState()
            configure(state)
            return AnyView(MenuPanelView(model: model, history: model.history, reminders: model.reminders,
                                         preferences: model.preferences, state: state, moment: Moment(frozen: now), actions: PanelActions()))
        }
        func settings(_ tab: SettingsState.Tab, scene: SampleData.Scene = .watching,
                      configure: (SettingsState, MonitorModel) -> Void = { _, _ in }) -> AnyView {
            let model = SampleData.model(now: now, scene: scene)
            let state = SettingsState()
            state.tab = tab
            configure(state, model)
            return AnyView(SettingsView(model: model, preferences: model.preferences, history: model.history,
                                        reminders: model.reminders, loginItem: model.loginItem, state: state,
                                        moment: Moment(frozen: now), actions: SettingsActions()))
        }
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
        func weekPanel(_ scene: SampleData.WeekScene, withDrops: Bool = false) -> AnyView {
            let model = SampleData.model(now: now, scene: scene == .timer ? .paused : .watching)
            if withDrops { SampleData.routines(in: model, now: now, scene: .kept) }
            SampleData.week(in: model, now: now, scene: scene)
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
            ("panel-demo", panel(.demo)),
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
            ("settings-breaks", settings(.breaks, scene: .learning)),
            ("settings-data", settings(.data)),
            ("panel-routine", routinePanel(.kept)),
            ("panel-routine-waiting", routinePanel(.waiting)),
            ("panel-routine-later", routinePanel(.putOff)),
            ("settings-routines", settings(.routines)),
            ("settings-routines-on", settings(.routines) { _, model in
                SampleData.routines(in: model, now: now, scene: .kept)
            }),
            ("panel-week", weekPanel(.toCome)),
            ("panel-week-waiting", weekPanel(.waiting)),
            ("panel-week-reached", weekPanel(.reached)),
            ("panel-week-timer", weekPanel(.timer)),
            ("panel-week-with-times", weekPanel(.toCome, withDrops: true)),
            ("settings-routines-week", settings(.routines) { _, model in
                SampleData.week(in: model, now: now, scene: .toCome)
            }),
            ("panel-own", ownPanel(.counting)),
            ("panel-own-waiting", ownPanel(.waiting)),
            ("panel-many", ownPanel(.many)),
            ("panel-many-all", ownPanel(.manyShown)),
            ("panel-many-quiet", ownPanel(.quiet)),
            ("settings-routines-own", settings(.routines) { _, model in
                SampleData.own(in: model, now: now, scene: .counting)
            }),
            ("settings-routines-many", settings(.routines) { _, model in
                SampleData.own(in: model, now: now, scene: .many)
            }),
            ("routine-timer", routineTimer(.timer)),
            ("routine-timer-done", routineTimer(.timerDone)),
            ("blink-break", blinkBreak(.blinkBreak(count: 6))),
            ("blink-break-done", blinkBreak(.blinkBreak(count: 10))),
            ("welcome", AnyView(WelcomeView(start: {}))),
            ("live-view", AnyView(LiveView(model: watching, captures: watching.captures))),
        ]
    }
}
