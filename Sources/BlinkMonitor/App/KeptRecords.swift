import Foundation
import BlinkCore
import BlinkUI

/// One of the files of numbers and words the app keeps about what happened: the history,
/// the routine log, the break log, the eye notes (each a `RecordFile`).
///
/// THEY ARE LISTED ONCE, HERE. The Privacy tab shows a row for each, Export copies each,
/// and "Delete Everything" names each. Before, a new record meant a row in the Privacy
/// tab, a line in the export, a parameter of the export panel and of its caller, and two
/// sentences that named them all: seven places, and nothing failed when one was forgotten.
struct KeptRecord: Identifiable {
    /// Its name inside a sentence, after "your": "history", "routine log".
    let name: String
    /// Its row in the Privacy tab.
    let title: String
    let detail: String
    let file: URL
    /// The name of its copy in a folder of the user's: in someone's Documents,
    /// "history.csv" would say nothing, and could be another program's.
    let exportName: String
    let eraseQuestion: Confirm.Question
    /// There is something to erase besides the file itself (the history's minutes in
    /// memory, and the usual rate measured from them).
    var holdsMore: () -> Bool = { false }
    let erase: () -> Void

    var id: String { exportName }

    var exportItem: DataExport.Item { DataExport.Item(file: file, name: exportName) }

    /// "your history, your routine log, your break log, your eye notes".
    static func names(_ records: [KeptRecord]) -> String {
        records.map { "your \($0.name)" }.joined(separator: ", ")
    }
}

extension MonitorModel {

    /// Every record the app keeps, in the order the Privacy tab and Export show them.
    var keptRecords: [KeptRecord] {
        [KeptRecord(name: "history", title: "History file",
                    detail: "\(Format.count(history.minutes.count, "minute")) from the last \(HistoryController.daysKept) days are shown. "
                        + "The file keeps every minute since the first, and Erase removes all of them.",
                    file: history.store.file, exportName: "Blink - history.csv",
                    eraseQuestion: EraseWords.history(startingLimit: preferences.floor),
                    holdsMore: { [weak self] in self.map { !$0.history.minutes.isEmpty || $0.preferences.reference != nil } ?? false },
                    erase: { [weak self] in self?.eraseHistory() }),
         KeptRecord(name: "routine log", title: "Routine log",
                    detail: "What you did with your routines, one line each time. It opens in any spreadsheet.",
                    file: routines.store.file, exportName: "Blink - routine log.csv",
                    eraseQuestion: EraseWords.routineLog, erase: { [weak self] in self?.routines.eraseRecord() }),
         // A dash stands between the app's name and the record: "Blink break log" read as
         // a log of blink breaks, and the file holds the look-away breaks and reminders too.
         KeptRecord(name: "break log", title: KeptWords.fileTitle, detail: KeptWords.fileDetail,
                    file: care.store.file, exportName: "Blink - break log.csv",
                    eraseQuestion: EraseWords.breakLog, erase: { [weak self] in self?.care.erase() }),
         KeptRecord(name: "eye notes", title: EyeNoteWords.fileTitle, detail: EyeNoteWords.fileDetail,
                    file: eyeNotes.store.file, exportName: "Blink - eye notes.csv",
                    eraseQuestion: EraseWords.eyeNotes, erase: { [weak self] in self?.eyeNotes.erase() })]
    }
}
