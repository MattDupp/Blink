import Foundation

/// "Export…": copies of the app's two files of numbers, in a folder the user chose.
///
/// The history (one line per minute counted) and the routine log (one line each time a
/// reminder was shown, done, postponed or missed). Both are plain CSV, so any spreadsheet
/// opens them. Nothing is sent anywhere: this is a copy from one folder of this Mac to
/// another, and the app goes on writing to its own files, not to the copies.
///
/// The copies get names that say where they come from. In the app's folder the files are
/// "history.csv" and "routines.csv"; in someone's Documents those names would say nothing,
/// and could be another program's.
public enum DataExport {

    /// One file to export: where it is, and the name of its copy.
    public struct Item: Equatable {
        public let file: URL
        public let name: String

        public init(file: URL, name: String) {
            self.file = file
            self.name = name
        }
    }

    public static func items(history: URL, routineLog: URL, breakLog: URL, eyeNotes: URL) -> [Item] {
        [Item(file: history, name: "Blink Monitor history.csv"),
         Item(file: routineLog, name: "Blink Monitor routine log.csv"),
         Item(file: breakLog, name: "Blink Monitor break log.csv"),
         Item(file: eyeNotes, name: "Blink Monitor eye notes.csv")]
    }

    /// Copies each file that exists into `folder`, and answers the copies made. A file
    /// that does not exist yet (no routine was ever shown) is left out, not an error. A
    /// copy from an earlier export, under the same name, is replaced.
    @discardableResult
    public static func copy(_ items: [Item], to folder: URL, files: FileManager = .default) throws -> [URL] {
        var copies: [URL] = []
        for item in items where files.fileExists(atPath: item.file.path) {
            let copy = folder.appendingPathComponent(item.name)
            if files.fileExists(atPath: copy.path) { try files.removeItem(at: copy) }
            try files.copyItem(at: item.file, to: copy)
            copies.append(copy)
        }
        return copies
    }
}
