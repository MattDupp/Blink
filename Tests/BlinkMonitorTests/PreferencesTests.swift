import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

/// The choices the app remembers.
@MainActor
@Suite("Preferences")
struct PreferencesTests {

    /// A store of its own for one test, emptied before and after.
    private func withStore(_ body: (UserDefaults) -> Void) {
        let name = "local.blinkmonitor.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        defer { store.removePersistentDomain(forName: name) }
        body(store)
    }

    @Test("What was stored is read back through each choice's own rule, and what cannot be read stays at the standard")
    func storedChoicesReadBack() {
        withStore { store in
            store.set("controlShiftCommandB", forKey: "blinkBreakShortcut")
            store.set(30, forKey: "summaryHour")                // out of the day: the last hour
            store.set(-4, forKey: "eyeNoteHour")                // the first
            store.set([0, 2, 9, 6], forKey: "workingHoursDays") // only the days of a week
            store.set(8 * 60 + 45, forKey: "workingHoursStart")
            store.set("turbo", forKey: "effort")                // a word of a later version
            store.set("desk", forKey: "cameraID")
            let read = Preferences(defaults: store)
            #expect(read.blinkBreakShortcut == .controlShiftCommandB)
            #expect(read.summaryHour == 23 && read.eyeNoteHour == 0)
            #expect(read.workDays == [2, 6])
            #expect(read.workStart == TimeOfDay(hour: 8, minute: 45))
            #expect(read.effort == .standard)
            #expect(read.cameraID == "desk")
            #expect(read.hasChoices)
            read.resetChoices()
            #expect(!read.hasChoices && read.blinkBreakShortcut == nil && read.cameraID == nil)
        }
    }

    @Test("An install starts at the floor the experiment gives, welcomed or not")
    func startingFloor() {
        withStore { store in
            let first = Preferences(defaults: store)
            #expect(first.floor == PublishedRates.startingFloor && first.limit == PublishedRates.startingFloor)
            first.welcomed = true
            #expect(Preferences(defaults: store).floor == PublishedRates.startingFloor)
        }
    }

    @Test("The floor can be set as low as 1, so that a limit can follow someone who blinks very little")
    func lowestFloor() {
        #expect(Preferences.floorChoices.lowerBound == 1)
        #expect(Preferences.floorChoices.contains(PublishedRates.startingFloor))

        withStore { store in
            // Somebody who makes 1.6 complete blinks a minute at a screen, floor at its lowest.
            let preferences = Preferences(defaults: store)
            preferences.reference = Reference(rate: 1.6, measuredOn: Date(timeIntervalSince1970: 1_800_000_000), minutes: 200)
            #expect(Baseline.limitAboveUsual(reference: preferences.reference, limit: preferences.limit), "at the starting floor")
            preferences.floor = Preferences.floorChoices.lowerBound
            #expect(preferences.limit == 1)
            #expect(!Baseline.limitAboveUsual(reference: preferences.reference, limit: preferences.limit))
            // The choice is kept.
            #expect(Preferences(defaults: store).floor == 1)
        }
    }

    @Test("The effort is Standard until chosen, is kept, and a word this version does not know reads as Standard")
    func effort() {
        withStore { store in
            let preferences = Preferences(defaults: store)
            #expect(preferences.effort == .standard && !preferences.hasChoices)
            preferences.effort = .thorough
            #expect(preferences.hasChoices)
            #expect(Preferences(defaults: store).effort == .thorough)
            store.set("extreme", forKey: "effort")
            #expect(Preferences(defaults: store).effort == .standard)
        }
    }

    @Test("Reset to Defaults puts every choice back, and keeps what was measured or lived")
    func resetChoices() {
        withStore { store in
            let preferences = Preferences(defaults: store)
            #expect(!preferences.hasChoices, "a new install has nothing to reset")
            let measured = Reference(rate: 12.4, measuredOn: Date(timeIntervalSince1970: 1_800_000_000), minutes: 200)
            let pausedUntil = Date(timeIntervalSince1970: 1_800_003_600)
            // What was measured or lived, and the routines, which share the store.
            preferences.reference = measured
            preferences.welcomed = true
            preferences.pause = .paused(until: pausedUntil)
            preferences.quietUntil = pausedUntil
            store.set(Data([1, 2, 3]), forKey: "routines")
            // Choices, one of each kind.
            preferences.showRateInMenuBar = false
            preferences.blinkBack = false
            preferences.remindersOn = false
            preferences.automaticLimit = false
            preferences.floor = 4
            preferences.ownRateOfferAnswered = true
            preferences.breakPlan = BreakPlan(workMinutes: 25, breakSeconds: 40, longEvery: 4, longMinutes: 7)
            preferences.breakNudgesOn = true
            preferences.breakEndSound = false
            preferences.pauseOnBattery = true
            preferences.effort = .light
            preferences.quietDuringCalls = true
            preferences.liveViewSound = true
            preferences.cameraID = "desk"
            #expect(preferences.hasChoices)

            preferences.resetChoices()

            // As a new install reads them, now and after a relaunch.
            for read in [preferences, Preferences(defaults: store)] {
                #expect(!read.hasChoices)
                #expect(read.showRateInMenuBar && read.blinkBack && read.remindersOn && read.automaticLimit)
                #expect(read.floor == PublishedRates.startingFloor && !read.ownRateOfferAnswered)
                #expect(read.breakPlan == BreakPlan.Preset.classic.plan && !read.breakNudgesOn && read.breakEndSound)
                #expect(!read.pauseOnBattery && !read.quietDuringCalls && !read.liveViewSound && read.cameraID == nil)
                #expect(read.effort == .standard)
                // Kept.
                #expect(read.reference == measured && read.welcomed)
                #expect(read.pause == .paused(until: pausedUntil) && read.quietUntil == pausedUntil)
            }
            #expect(store.data(forKey: "routines") == Data([1, 2, 3]), "the routines are not choices of Settings")
            #expect(EraseWords.choices.text.contains("Your usual rate") && EraseWords.choices.text.hasSuffix("This cannot be undone."))
        }
    }

    @Test("Quiet outside working hours is off until chosen, is kept, and Reset takes it back")
    func workingHours() {
        withStore { store in
            let preferences = Preferences(defaults: store)
            #expect(!preferences.workingHoursOn && preferences.workingHours == nil, "quiet by default: nothing changes untouched")
            preferences.workingHoursOn = true
            preferences.workStart = TimeOfDay(hour: 8, minute: 30)
            preferences.workDays = [2, 3]
            let read = Preferences(defaults: store)
            #expect(read.workingHours == WorkingHours(start: TimeOfDay(hour: 8, minute: 30), end: TimeOfDay(hour: 18), weekdays: [2, 3]))
            #expect(read.hasChoices)
            read.resetChoices()
            #expect(!read.hasChoices && Preferences(defaults: store).workingHours == nil)
            #expect(Preferences(defaults: store).workStart == WorkingHours.usual.start)
        }
    }

    @Test("Outside the working hours the reminders are quiet, and the panel says why and until when")
    func quietOutsideHours() {
        withStore { store in
            let preferences = Preferences(defaults: store)
            let reminders = ReminderController(preferences: preferences)
            let calendar = Calendar.current
            // Saturday 21 November 2026 at 11:00, on this Mac's clock.
            let saturday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 11)) ?? Date()
            let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9)) ?? Date()
            #expect(reminders.quietReason(now: saturday) == nil && reminders.mayShowRoutineBanner(now: saturday))
            preferences.workingHoursOn = true        // read at the next question, nothing to keep in step
            #expect(reminders.quietReason(now: saturday) == .outsideHours(until: monday))
            #expect(reminders.isQuiet(now: saturday) && !reminders.mayShowRoutineBanner(now: saturday))
            let line = QuietWords.line(.outsideHours(until: monday), now: saturday)
            #expect(line.hasPrefix("Quiet until ") && line.contains("outside your working hours") && line.contains(QuietWords.effect))
            #expect(line.contains(Format.ahead(monday, from: saturday)) && Format.ahead(monday, from: saturday) != Format.time(monday),
                    "two days ahead, the day is named")
            // The Quiet chosen in the panel keeps its own sentence, with the same effect.
            #expect(QuietWords.line(.chosen(until: monday), now: saturday).contains(QuietWords.effect))
            preferences.workingHoursOn = false
            #expect(reminders.quietReason(now: saturday) == nil)
        }
    }

    @Test("The shortcut for a blink break: none until chosen, registered when the app starts it, a refusal said")
    func shortcut() {
        /// Stands for macOS: it refuses one combination, as when another app holds it.
        @MainActor final class StatedKeys: HotKeys {
            var held: ShortcutChoice?
            var press: () -> Void = {}
            var asked = 0
            func register(_ choice: ShortcutChoice, pressed: @escaping () -> Void) -> Bool {
                asked += 1
                guard choice != .controlShiftCommandB else { return false }
                (held, press) = (choice, pressed)
                return true
            }
            func unregister() { (held, press) = (nil, {}) }
        }
        withStore { store in
            let preferences = Preferences(defaults: store)
            #expect(preferences.blinkBreakShortcut == nil && !preferences.hasChoices, "off by default")
            let keys = StatedKeys()
            let controller = ShortcutController(preferences: preferences, keys: keys)
            preferences.blinkBreakShortcut = .controlOptionCommandB
            #expect(keys.asked == 0, "nothing is taken from this Mac before the app starts it")
            var presses = 0
            controller.start { presses += 1 }
            #expect(keys.held == .controlOptionCommandB && controller.refused == nil)
            keys.press()
            #expect(presses == 1)
            // Kept across a relaunch.
            #expect(Preferences(defaults: store).blinkBreakShortcut == .controlOptionCommandB)
            // macOS refuses the next one: nothing is held, and the row says so by name.
            preferences.blinkBreakShortcut = .controlShiftCommandB
            #expect(keys.held == nil && controller.refused == .controlShiftCommandB)
            let said = ShortcutWords.detail(chosen: preferences.blinkBreakShortcut, refused: controller.refused)
            #expect(said.contains("⌃⇧⌘B") && said.contains("Choose another"))
            // Another choice is accepted, and the refusal is forgotten.
            preferences.blinkBreakShortcut = .optionShiftCommandB
            #expect(keys.held == .optionShiftCommandB && controller.refused == nil)
            // Off, and Reset to Defaults, give the key back.
            preferences.blinkBreakShortcut = .controlOptionShiftB
            preferences.resetChoices()
            #expect(keys.held == nil && preferences.blinkBreakShortcut == nil)
            controller.stop()
            preferences.blinkBreakShortcut = .controlOptionCommandB
            #expect(keys.held == nil, "a stopped controller takes nothing")
        }
        // Four different combinations, each with three modifier keys and B.
        #expect(Set(ShortcutChoice.allCases.map(\.modifiers)).count == ShortcutChoice.allCases.count)
        for choice in ShortcutChoice.allCases {
            #expect(choice.modifiers.nonzeroBitCount == 3 && choice.symbols.hasSuffix("B") && choice.symbols.count == 4)
        }
    }

    @Test("Larger text: off until chosen, untouched fonts while off, every style larger while on")
    func largerText() {
        withStore { store in
            let preferences = Preferences(defaults: store)
            #expect(!preferences.largerText && !preferences.hasChoices)
            preferences.largerText = true
            #expect(Preferences(defaults: store).largerText && preferences.hasChoices)
            preferences.resetChoices()
            #expect(!Preferences(defaults: store).largerText)
        }
        // Off: the system's own font, so nothing differs for whoever touches nothing.
        #expect(TextScale.font(.callout, scale: 1) == Font.system(.callout))
        #expect(TextScale.font(.caption, weight: .semibold, scale: 1) == Font.system(.caption).weight(.semibold))
        #expect(TextScale.font(.title, weight: .bold, design: .rounded, scale: 1) == Font.system(.title, design: .rounded).weight(.bold))
        // On: each style at its size times the scale, in whole points, with its own weight.
        #expect(TextScale.font(.callout, scale: TextScale.larger) == Font.system(size: 14, weight: .regular, design: .default))
        #expect(TextScale.font(.headline, scale: TextScale.larger) == Font.system(size: 16, weight: .bold, design: .default))
        #expect(TextScale.font(.caption, weight: .semibold, scale: TextScale.larger) == Font.system(size: 12, weight: .semibold, design: .default))
        // No style gets smaller than the one above it was.
        let styles: [Font.TextStyle] = [.caption2, .caption, .subheadline, .callout, .body, .title3, .title2, .title, .largeTitle]
        let sizes = styles.map(TextScale.points)
        #expect(sizes == sizes.sorted() && sizes.first == 10)
    }

    @Test("A floor somebody chose is never replaced")
    func chosenFloor() {
        withStore { store in
            store.set(8, forKey: "threshold")
            #expect(Preferences(defaults: store).floor == 8)
            store.set(true, forKey: "welcomed")
            #expect(Preferences(defaults: store).floor == 8)
        }
    }
}
