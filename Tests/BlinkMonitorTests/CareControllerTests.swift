import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

/// The break log as the app keeps it, on a file of the test's own.
@MainActor
@Suite("The break log")
struct CareControllerTests {

    @Test("What the app did is written down, shown in History's words, and erased on request")
    func log() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-care-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let care = CareController(store: CareStore(file: folder.appendingPathComponent("breaks.csv")))
        #expect(care.events.isEmpty && KeptWords.lines(Kept()).isEmpty, "nothing kept, nothing said")
        // (The file keeps whole seconds.)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        care.record(CareEvent(BreakOutcome(kind: .short, ending: .away), at: now))
        care.record(.blinkReminder, now: now)
        care.record(.blinkBreak, now: now)
        // A relaunch reads them back.
        #expect(CareController(store: care.store).events == care.events && care.events.count == 3)
        let kept = Kept(week: HistoryWeeks.week(0, now: now, calendar: .current), care: care.events,
                        routines: [RoutineEvent(at: now, routine: "eye-drops", slot: "a", action: .done)])
        #expect(KeptWords.lines(kept).map(\.text) == ["1 look-away break taken", "1 blink break finished, 1 blink reminder shown",
                                                      "Routines marked done once"])
        care.erase()
        #expect(care.events.isEmpty && !FileManager.default.fileExists(atPath: care.store.file.path))
    }

    @Test("A model's files are in a scratch folder of its own unless the user's own are asked for by name")
    func dataPlace() {
        let one = MonitorModel(preferences: .temporary()), two = MonitorModel(preferences: .temporary())
        let files = [one.history.store.file, one.care.store.file, one.eyeNotes.store.file, one.routines.store.file, one.modelStore.base]
        let temporary = FileManager.default.temporaryDirectory.path
        #expect(files.allSatisfy { $0.path.hasPrefix(one.place.folder.path) && $0.path.hasPrefix(temporary) })
        #expect(one.place.folder != two.place.folder, "two made-up models never share a file")
        // The user's own: the files the app has always used.
        let real = DataPlace.real
        #expect([real.history.file, real.care.file, real.eyeNotes.file, real.routines.file]
                    == [HistoryStore.defaultFile, CareStore.defaultFile, EyeNoteStore.defaultFile, RoutineStore.defaultFile])
        #expect(real.models.base == ModelStore.standard.base && real.sessions == SessionStore.standardRoot)
    }

    @Test("The model writes a finished blink break to its log, and a made-up model never touches the real file")
    func hooks() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blink-care-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = MonitorModel(preferences: .temporary(), place: DataPlace(folder: folder), initial: MonitorModel.InitialState())
        let care = model.care
        model.blinkBreak.onDone()
        model.reminders.onBlinkReminder(Date())
        model.reminders.breaks.onOutcome(BreakOutcome(kind: .short, ending: .skipped), Date())
        #expect(care.events.map(\.kind) == [.blinkBreak, .blinkReminder, .skipped])
        // The demo and the screenshots: a log in the temporary folder.
        let sample = MonitorModel(preferences: .temporary(), initial: MonitorModel.InitialState())
        #expect(sample.care.store.file != CareStore.defaultFile)
        #expect(sample.care.store.file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test("The comparison is two numbers of the person's own, and says that they explain nothing")
    func findingWords() {
        let said = KeptWords.finding(KeptFinding(breaks: 6, daysWith: 9, rateWith: 14.1, daysWithout: 7, rateWithout: 11.3))
        #expect(said.contains("On the 9 days with 6 or more look-away breaks") && said.contains("On the 7 other days"))
        #expect(said.hasSuffix("they do not say why."))
        // No cause, no promise, no advice.
        for word in ["because", "help", "should", "improve", "better", "thanks to", "cause", "try"] {
            #expect(!said.lowercased().contains(word), "\(word)")
        }
    }
}
