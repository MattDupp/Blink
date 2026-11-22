import Foundation
import CoreGraphics

/// The two answers the model learns to give. These words are the folder names on disk
/// and, in the end, what the model's output means.
public enum EyeLabel: String {
    case open
    case closed
}

/// One labelled eye picture, with everything known about it.
public struct EyeSample {
    public let image: CGImage
    public let label: EyeLabel
    /// A short name for the pose ("keyboard", "tilt"...). It lets us ask later "on which
    /// poses does the model fail?" instead of only "how often does it fail?".
    public let variant: String
    public let phaseIndex: Int
    public let frameIndex: Int
    public let time: Double
    public let eye: EyeRegion
    public let located: LocatedEyes
    public let frameSize: CGSize

    public init(image: CGImage, label: EyeLabel, variant: String, phaseIndex: Int, frameIndex: Int,
                time: Double, eye: EyeRegion, located: LocatedEyes, frameSize: CGSize) {
        self.image = image
        self.label = label
        self.variant = variant
        self.phaseIndex = phaseIndex
        self.frameIndex = frameIndex
        self.time = time
        self.eye = eye
        self.located = located
        self.frameSize = frameSize
    }
}

/// Writes one recording session to disk:
///
///     <root>/<session>/open/p00_f000123_L.png
///     <root>/<session>/closed/p01_f000260_R.png
///     <root>/<session>/manifest.csv
///
/// One folder PER SESSION matters more than it looks. To know whether a model really
/// works we test it on pictures it never trained on. Pictures of one session are near
/// copies of each other, so a test made of random pictures would be an exam whose answers
/// were handed out beforehand. Whole sessions are held back for testing instead - and
/// that is only possible because each picture remembers its session.
public final class SessionWriter {

    public let folder: URL
    private let sessionID: String
    private let condition: String
    private let manifest: CSVAppender

    /// The columns of manifest.csv: one line per picture.
    public static let header = "session,condition,phase,label,variant,frame,time,side,file,"
        + "crop_x,crop_y,crop_side,eye_distance,roll,yaw,frame_w,frame_h"

    public init(root: URL, session: String, condition: String) throws {
        sessionID = session
        self.condition = Self.csvSafe(condition)

        folder = root.appendingPathComponent(session, isDirectory: true)
        for label in [EyeLabel.open, EyeLabel.closed] {
            try PrivateFolder.create(at: folder.appendingPathComponent(label.rawValue, isDirectory: true))
        }

        manifest = try CSVAppender(url: folder.appendingPathComponent("manifest.csv"), header: Self.header)
    }

    /// Free text typed by the user, made safe to sit in one CSV cell:
    ///   - commas, quotes and line breaks would break the line, so they become spaces;
    ///   - a cell that starts with = + - or @ is run as a FORMULA by spreadsheet programs
    ///     when the file is opened there, so those leading characters are dropped.
    static func csvSafe(_ text: String) -> String {
        let oneLine = text
            .components(separatedBy: CharacterSet(charactersIn: ",\"\r\n\t"))
            .joined(separator: " ")
            .split(separator: " ")
            .joined(separator: " ")
        return String(oneLine.drop { "=+-@ ".contains($0) })
    }

    /// Saves one eye picture and its manifest line. Returns false when the disk refused.
    @discardableResult
    public func save(_ sample: EyeSample) -> Bool {
        let name = String(format: "p%02d_f%06d_%@.png", sample.phaseIndex, sample.frameIndex, sample.eye.side.rawValue)
        let relative = "\(sample.label.rawValue)/\(name)"
        guard PNGFile.write(sample.image, to: folder.appendingPathComponent(relative)) else { return false }

        func angle(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        let rect = sample.eye.cropRect
        let fields: [String] = [
            sessionID, condition, String(sample.phaseIndex), sample.label.rawValue, sample.variant,
            String(sample.frameIndex), String(format: "%.3f", sample.time), sample.eye.side.rawValue, relative,
            String(Int(rect.minX)), String(Int(rect.minY)), String(Int(rect.width)),
            String(format: "%.1f", sample.located.interocularDistance),
            angle(sample.located.roll), angle(sample.located.yaw),
            String(Int(sample.frameSize.width)), String(Int(sample.frameSize.height)),
        ]
        return manifest.append(fields)
    }
}

/// One recorded session, as counted on disk.
public struct SessionSummary: Equatable {
    /// The folder's name: the date and time the session began (20261120-101147).
    public let name: String
    public let folder: URL
    public let open: Int
    public let closed: Int

    public var pictures: Int { open + closed }

    public init(name: String, folder: URL, open: Int, closed: Int) {
        self.name = name
        self.folder = folder
        self.open = open
        self.closed = closed
    }
}

/// The sessions on disk: which is the latest, and how to throw one away.
///
/// A session is one folder, and nothing else refers to it: its pictures and its
/// manifest.csv live inside. So discarding a session is removing ONE folder - never
/// emptying it by hand, which leaves a session with a manifest and no pictures behind.
public enum SessionStore {

    /// Where the app keeps the sessions it records, unless it is told another folder:
    /// ~/Library/Application Support/BlinkMonitor/sessions.
    public static var standardRoot: URL {
        HistoryStore.applicationFolder.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Every session that holds a manifest, oldest first, with its pictures counted.
    public static func sessions(in root: URL) -> [SessionSummary] {
        let files = FileManager.default
        let folders = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { $0.hasDirectoryPath && files.fileExists(atPath: $0.appendingPathComponent("manifest.csv").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { folder in
                func count(_ label: EyeLabel) -> Int {
                    let names = (try? files.contentsOfDirectory(atPath: folder.appendingPathComponent(label.rawValue).path)) ?? []
                    return names.filter { $0.hasSuffix(".png") }.count
                }
                return SessionSummary(name: folder.lastPathComponent, folder: folder, open: count(.open), closed: count(.closed))
            }
    }

    /// The disk space of everything under a folder, in bytes.
    public static func bytes(under folder: URL) -> Int {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        for case let file as URL in files ?? FileManager.DirectoryEnumerator() {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// The most recent session folder. Their names are dates (20261120-101147), so the
    /// last one in alphabetical order is the newest.
    public static func latest(in root: URL) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { $0.hasDirectoryPath }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Removes a whole session. `toTrash` puts it in the Trash, where a mistake can still
    /// be undone; without it the folder is deleted for good.
    public static func discard(_ folder: URL, toTrash: Bool) throws {
        if toTrash {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: folder)
        }
    }
}

/// How many pictures are on disk, over every session.
public struct DatasetStats: Equatable {
    public var sessions = 0
    public var open = 0
    public var closed = 0

    public init(sessions: Int = 0, open: Int = 0, closed: Int = 0) {
        self.sessions = sessions
        self.open = open
        self.closed = closed
    }

    public static func scan(_ root: URL) -> DatasetStats {
        var stats = DatasetStats()
        let files = FileManager.default
        guard let sessions = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return stats }
        for session in sessions where session.hasDirectoryPath {
            func count(_ label: EyeLabel) -> Int {
                let names = (try? files.contentsOfDirectory(atPath: session.appendingPathComponent(label.rawValue).path)) ?? []
                return names.filter { $0.hasSuffix(".png") }.count
            }
            let open = count(.open), closed = count(.closed)
            if open + closed > 0 {
                stats.sessions += 1
                stats.open += open
                stats.closed += closed
            }
        }
        return stats
    }
}
