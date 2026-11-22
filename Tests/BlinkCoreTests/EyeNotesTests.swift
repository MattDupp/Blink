import Foundation
import Testing
@testable import BlinkCore

/// The notes of the evening question, on a file of the test's own.
@Suite("How the eyes feel: the notes")
struct EyeNotesTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        return calendar
    }

    private func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour)) ?? Date()
    }

    @Test("A file of its own: written, read back, erased, and gone with Delete Everything")
    func store() throws {
        let base = Fixture.temporaryFolder()
        let folder = base.appendingPathComponent("BlinkMonitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = EyeNoteStore(file: folder.appendingPathComponent("eye-notes.csv"))
        #expect(store.load().isEmpty, "no file yet is not an error")
        let notes = [EyeNote(feeling: .aLittleTired, at: at(19, 18), calendar: calendar),
                     EyeNote(feeling: .fine, at: at(20, 18), calendar: calendar)]
        for note in notes { #expect(store.append(note)) }
        #expect(store.load() == notes)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(text.hasPrefix("day,at,feeling\n2026-11-19,") && text.hasSuffix(",fine\n"))
        // The history's own file was not touched, and does not exist here.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("history.csv").path))
        // A word the app does not know is skipped: the file is the person's, and may be edited.
        try (text + "2026-11-21,2026-11-21T17:00:00Z,sparkling\n").write(to: store.file, atomically: true, encoding: .utf8)
        #expect(store.load() == notes)

        #expect(store.erase() && store.load().isEmpty && store.erase())
        store.append(notes[0])
        let domain = "local.blinkmonitor.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        try Uninstall.deleteEverything(folder: folder, defaults: defaults, domain: domain)
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
    }

    @Test("One note a day: the last answer of a day is its note, and a week shows a note or nothing for each day")
    func row() {
        let notes = [EyeNote(feeling: .tired, at: at(16, 18), calendar: calendar),
                     EyeNote(feeling: .fine, at: at(18, 18), calendar: calendar),
                     EyeNote(feeling: .veryTired, at: at(18, 21), calendar: calendar),      // changed the same evening
                     EyeNote(feeling: .aLittleTired, at: at(10, 18), calendar: calendar)]   // the week before
        #expect(EyeNotes.byDay(notes)["2026-11-18"] == .veryTired)
        let week = HistoryWeeks.week(0, now: at(20, 16), calendar: calendar)                // 14 to 20 November
        #expect(EyeNotes.row(for: week, notes: notes, calendar: calendar) == [nil, nil, .tired, nil, .veryTired, nil, nil])
        let before = HistoryWeeks.week(1, now: at(20, 16), calendar: calendar)
        #expect(EyeNotes.row(for: before, notes: notes, calendar: calendar) == [nil, nil, nil, .aLittleTired, nil, nil, nil])
        // A note made just after midnight belongs to the new day, on the wall clock.
        #expect(EyeNote(feeling: .fine, at: at(21, 0), calendar: calendar).day == "2026-11-21")
    }
}
