import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

/// The optional evening question, on notes and settings of the test's own.
@MainActor
@Suite("How the eyes feel, in the app")
struct EyeNoteControllerTests {

    private func parts() -> (Preferences, EyeNoteController, URL) {
        let name = "local.blinkmonitor.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-notes-\(UUID().uuidString)", isDirectory: true)
        let preferences = Preferences(defaults: store)
        return (preferences, EyeNoteController(preferences: preferences, store: EyeNoteStore(file: folder.appendingPathComponent("eye-notes.csv"))), folder)
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date()
    }

    @Test("Off by default; on, it asks once from its hour on, waits for the gate, and does not ask a day already answered")
    func asks() {
        let (preferences, notes, folder) = parts()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!preferences.eyeNoteOn && !preferences.hasChoices)
        var asked = 0, allowed = true, shownAt: [Date] = []
        notes.onAsked = { asked += 1 }
        notes.turns = BannerTurns { _, now, show in
            if allowed, show() { shownAt.append(now) }
        }

        notes.askIfDue(now: at(18))
        #expect(asked == 0, "off: no question")
        preferences.eyeNoteOn = true
        notes.askIfDue(now: at(16, 59))
        #expect(asked == 0, "not before its hour")
        allowed = false                              // Quiet, a break, the working hours: the gate says no
        notes.askIfDue(now: at(17, 1))
        #expect(asked == 0 && preferences.eyeNoteAskedDay == nil, "held back is not asked: it comes when the gate opens")
        allowed = true
        notes.askIfDue(now: at(17, 5))
        #expect(asked == 1 && shownAt == [at(17, 5)], "it takes its place between the other banners")
        notes.askIfDue(now: at(17, 30))
        #expect(asked == 1, "once a day")

        // The next day it was answered in History before the hour: nothing is asked.
        notes.note(.aLittleTired, now: at(15, day: 21))
        notes.askIfDue(now: at(17, 5, day: 21))
        #expect(asked == 1 && notes.today(now: at(18, day: 21)) == .aLittleTired)
        // An answer changed the same day replaces the first; yesterday has none.
        notes.note(.fine, now: at(19, day: 21))
        #expect(notes.today(now: at(20, day: 21)) == .fine && notes.today(now: at(20)) == nil)
        // A relaunch reads the notes back; Erase removes them and the file.
        #expect(EyeNoteController(preferences: preferences, store: notes.store).notes.count == 2)
        notes.erase()
        #expect(notes.notes.isEmpty && !FileManager.default.fileExists(atPath: notes.store.file.path))
        preferences.resetChoices()
        #expect(!preferences.eyeNoteOn)
    }

    @Test("The question goes through the one gate, and a made-up model never touches the real file")
    func gate() {
        let model = MonitorModel(preferences: .temporary(), initial: MonitorModel.InitialState())
        #expect(model.eyeNotes.store.file != EyeNoteStore.defaultFile)
        #expect(model.eyeNotes.store.file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        model.preferences.eyeNoteOn = true
        var asked = 0
        model.eyeNotes.onAsked = { asked += 1 }
        let now = at(17, 5)
        model.reminders.setQuiet(until: now.addingTimeInterval(600))
        model.eyeNotes.askIfDue(now: now)
        #expect(asked == 0, "Quiet holds it")
        model.reminders.setQuiet(until: nil)
        model.eyeNotes.askIfDue(now: now.addingTimeInterval(660))
        #expect(asked == 1)
        #expect(!model.reminders.mayShowRoutineBanner(now: now.addingTimeInterval(700)), "two minutes before any other banner")
    }

    @Test("Four plain words, and nothing that interprets, diagnoses or advises")
    func words() {
        #expect(EyeFeeling.allCases.map(EyeNoteWords.name) == ["Fine", "A little tired", "Tired", "Very tired"])
        let everything = [EyeNoteWords.question, EyeNoteWords.bannerBody, EyeNoteWords.rowTitle, EyeNoteWords.row, EyeNoteWords.detail,
                          EyeNoteWords.hourDetail, EyeNoteWords.fileDetail, EraseWords.eyeNotes.text].joined(separator: " ").lowercased()
        for word in ["dry eye", "symptom", "diagnos", "treat", "doctor", "should", "because", "improv", "better", "worse", "help", "strain", "pain"] {
            #expect(!everything.contains(word), "\(word)")
        }
        #expect(EyeNoteWords.detail.contains("does nothing else with it") && EraseWords.eyeNotes.text.hasSuffix("This cannot be undone."))
    }
}
