import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

@MainActor
@Suite("Settings")
struct SettingsWordsTests {

    @Test("Every record the app keeps is listed once: in Privacy, in Export and in Delete Everything")
    func keptRecords() {
        let model = MonitorModel(preferences: .temporary(), initial: MonitorModel.InitialState())
        let records = model.keptRecords
        #expect(records.map(\.exportName) == ["Blink - history.csv", "Blink - routine log.csv", "Blink - break log.csv",
                                               "Blink - eye notes.csv"])
        #expect(Set(records.map(\.file)).count == records.count, "one file each")
        #expect(Set(records.map(\.exportName)).count == records.count, "one name each")
        let everything = EraseWords.everything(records).text, export = ExportPanel.message(records)
        for record in records {
            #expect(everything.contains("your \(record.name)"), "\(record.name)")
            #expect(export.contains("your \(record.name)"), "\(record.name)")
            #expect(record.eraseQuestion.text.contains("cannot be undone"), "\(record.name)")
        }
    }

    @Test("Seven tabs, the last one About; every erasing question says it cannot be undone")
    func tabsAndQuestions() {
        #expect(SettingsState.Tab.allCases.map(\.rawValue) == ["General", "Blink Rate", "Breaks", "Routines", "Model", "Privacy", "About"])
        let questions = [EraseWords.history(startingLimit: 10), EraseWords.routineLog, EraseWords.captures(2),
                         EraseWords.startAgain, EraseWords.everything([])]
        for question in questions {
            #expect(question.text.contains("cannot be undone"), "\(question.title)")
            #expect(question.button != "OK" && question.button != "Cancel")
        }
        #expect(EraseWords.history(startingLimit: 10).text.contains("goes back to 10"))
        #expect(EraseWords.captures(1).text.hasPrefix("1 capture of"))
    }

    @Test("Each effort says what it was measured to count, out of how many, and what it costs next to Standard")
    func effortWords() {
        #expect(Effort.allCases.map(EffortWords.name) == ["Light", "Standard", "Thorough"])
        for effort in Effort.allCases {
            let text = EffortWords.detail(effort), measured = effort.measured
            #expect(text.contains("counted \(measured.found) of \(measured.marked) blinks"), "\(text)")
            #expect(text.contains("\(effort.searchesASecond) times a second"), "\(text)")
            // Nothing the graphics processor has a part in, so nothing said about it.
            #expect(!text.lowercased().contains("graphics") && !text.contains("GPU"))
        }
        // The lower level says what it gives up beside what Standard counts; both others
        // say what they cost beside it.
        let standard = Effort.standard.measured.found
        #expect(EffortWords.detail(.light).contains("where Standard counted \(standard)"))
        #expect(EffortWords.detail(.light).contains("About 25% less processor work than Standard"))
        #expect(EffortWords.detail(.thorough).contains("About 70% more processor work than Standard"))
        #expect(!EffortWords.detail(.standard).contains("than Standard"))
        #expect(EffortWords.whileResting.contains("the camera is off"))
    }

    @Test("Erasing the routine log empties it and keeps the routines")
    func routineLogErased() throws {
        let routines = SampleData.demoModel().routines
        // The demo's log is a file of its own in the temporary folder: never the user's.
        try #require(routines.store.file.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let before = routines.routines
        routines.eraseRecord()
        #expect(routines.events.isEmpty && routines.routines == before)
    }
}
