import Foundation

/// One line of a capture's trace.csv: what was answered for one frame.
public struct TraceLine: Equatable {
    public var frame: Int
    public var time: Double
    /// The model's answers; nil for an eye that was not read.
    public var left: Double?
    public var right: Double?
    /// The two combined: what the blink detector was given.
    public var mean: Double?
    /// A blink was counted at this frame.
    public var blink: Bool

    public init(frame: Int, time: Double, left: Double? = nil, right: Double? = nil, mean: Double? = nil, blink: Bool = false) {
        self.frame = frame
        self.time = time
        self.left = left
        self.right = right
        self.mean = mean
        self.blink = blink
    }
}

/// A capture read back from disk: its trace, and the blinks a person marked in it.
public struct RecordedCapture {

    public enum FileError: Error, CustomStringConvertible {
        case unreadable(URL, String)

        public var description: String {
            switch self {
            case .unreadable(let file, let why): return "\(file.path): \(why)"
            }
        }
    }

    public let folder: URL
    /// trace.csv, as the app wrote it while recording.
    public let trace: [TraceLine]
    /// blinks.csv; nil when nobody has marked this capture yet (or not all of it).
    public let marks: [MarkedBlink]?

    public var name: String { folder.lastPathComponent }

    public init(folder: URL) throws {
        self.folder = folder
        trace = try Self.readTrace(folder.appendingPathComponent("trace.csv"))
        marks = try Self.readMarks(folder.appendingPathComponent("blinks.csv"))
    }

    /// True for a folder that holds a capture.
    public static func isCapture(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("trace.csv").path)
    }

    /// The captures in `root`, by name; `root` itself when it is one.
    public static func folders(in root: URL) -> [URL] {
        if isCapture(root) { return [root] }
        let inside = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return inside.filter(isCapture).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - What the lines say

    /// The numbers of the frames at which a blink was counted.
    public static func counted(in lines: [TraceLine]) -> [Int] {
        lines.filter(\.blink).map(\.frame)
    }

    /// From the first frame with both eyes read to the last, in seconds: the length
    /// evaluate.py gives a capture.
    public static func seconds(of lines: [TraceLine]) -> Double {
        let read = lines.filter { $0.left != nil && $0.right != nil }
        guard let first = read.first, let last = read.last else { return 0 }
        return last.time - first.time
    }

    /// How the blinks counted in `lines` compare with what a person marked.
    ///
    /// ONLY THE FRAMES WHERE BOTH EYES WERE READ ARE JUDGED, as in evaluate.py. The marks
    /// cover nothing else: annotate.py lays out candidates among those frames only, so a
    /// blink counted while one eye was hidden (head turned) was never shown to the person
    /// who marked, and calling it false would be inventing a verdict.
    /// SEEN on the capture 20261120-110029-free: the app counted 3 blinks on such frames;
    /// judged by frame number alone they came out as 3 false blinks that evaluate.py does
    /// not report.
    public static func score(_ lines: [TraceLine], against marks: [MarkedBlink]) -> BlinkScore {
        let read = lines.filter { $0.left != nil && $0.right != nil }
        // A mark names frame numbers; the judging is done in positions among `read`. A
        // marked frame that this run did not read takes the nearest one inside the mark.
        func firstPosition(from frame: Int) -> Int { read.firstIndex { $0.frame >= frame } ?? read.count }
        func lastPosition(upTo frame: Int) -> Int { (read.lastIndex { $0.frame <= frame }) ?? -1 }
        let placed = marks.map {
            MarkedBlink(firstFrame: firstPosition(from: $0.firstFrame), lastFrame: lastPosition(upTo: $0.lastFrame), kind: $0.kind)
        }
        return BlinkScore(counted: read.indices.filter { read[$0].blink }, marks: placed, seconds: seconds(of: lines))
    }

    // MARK: - Reading

    /// The lines of a CSV file as dictionaries, by column name.
    private static func rows(of file: URL) throws -> [[String: String]] {
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw FileError.unreadable(file, error.localizedDescription)
        }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { throw FileError.unreadable(file, "the file is empty") }
        let columns = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return lines.map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return Dictionary(zip(columns, fields), uniquingKeysWith: { first, _ in first })
        }
    }

    public static func readTrace(_ file: URL) throws -> [TraceLine] {
        try rows(of: file).map { row in
            guard let frame = row["frame"].flatMap(Int.init), let time = row["time"].flatMap(Double.init) else {
                throw FileError.unreadable(file, "a line has no frame number or no time")
            }
            return TraceLine(frame: frame, time: time,
                             left: row["p_left"].flatMap(Double.init), right: row["p_right"].flatMap(Double.init),
                             mean: row["p_mean"].flatMap(Double.init), blink: row["event"] == "blink")
        }
    }

    /// Nil when the file is absent, or when a candidate has not been given its kind yet:
    /// a capture half marked cannot be scored.
    public static func readMarks(_ file: URL) throws -> [MarkedBlink]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var marks: [MarkedBlink] = []
        for row in try rows(of: file) {
            guard let first = row["first_frame"].flatMap(Int.init), let last = row["last_frame"].flatMap(Int.init) else {
                throw FileError.unreadable(file, "a line has no first_frame or no last_frame")
            }
            guard let kind = row["kind"].flatMap(MarkedBlink.Kind.init(rawValue:)) else { return nil }
            marks.append(MarkedBlink(firstFrame: first, lastFrame: last, kind: kind))
        }
        return marks
    }
}
