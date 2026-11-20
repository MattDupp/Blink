import Foundation

/// Adds lines to a CSV file, creating it with its header line when it does not exist yet.
///
/// Four files of this project are written this way (the history, the performance log, a
/// session's manifest, a capture's trace). Each used to carry its own copy of "create the
/// folder, write the header, open, go to the end, write": this is that code, once.
///
/// The fields are joined with commas as they are. Callers pass numbers and fixed words;
/// free text must be made safe first (see `SessionWriter.csvSafe`).
public final class CSVAppender {

    private let handle: FileHandle

    public init(url: URL, header: String) throws {
        let files = FileManager.default
        if !files.fileExists(atPath: url.path) {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    /// Returns false (and logs why) when the line could not be written.
    @discardableResult
    public func append(_ fields: [String]) -> Bool {
        do {
            try handle.write(contentsOf: Data((fields.joined(separator: ",") + "\n").utf8))
            return true
        } catch {
            Log.storage.error("CSV line not written: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// The options given when the program was launched: `--flag` and `--name=value`.
public enum LaunchArguments {

    public static func has(_ flag: String) -> Bool {
        CommandLine.arguments.contains("--\(flag)")
    }

    public static func value(of name: String) -> String? {
        let prefix = "--\(name)="
        return CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    public static func folder(_ name: String) -> URL? {
        value(of: name).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
