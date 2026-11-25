import Foundation

/// "Export…": copies of the app's files of numbers and words, in a folder the user chose.
///
/// Which files, and the names of their copies, the app says (`KeptRecord`). They are plain
/// CSV, so any spreadsheet opens them. Nothing is sent anywhere: this is a copy from one
/// folder of this Mac to another, and the app goes on writing to its own files, not to
/// the copies.
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
