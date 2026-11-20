import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BlinkCore

/// Everything known about one saved picture.
struct Sample {
    let image: CGImage
    let phaseIndex: Int
    let phase: Phase
    let frameIndex: Int
    let time: Double
    let eye: EyeRegion
    let located: LocatedEyes
    let frameSize: CGSize
}

/// Writes one session to disk:
///
///     data/raw/<session>/open/p00_f000123_L.png
///     data/raw/<session>/closed/p01_f000260_R.png
///     data/raw/<session>/manifest.csv
///
/// One folder PER SESSION matters more than it looks. To know whether a model really
/// works we test it on pictures it never trained on. Pictures of one session are near
/// copies of each other, so a test made of random pictures would be an exam whose answers
/// were handed out beforehand. Later we will hold back WHOLE sessions for testing - and
/// that is only possible because each picture remembers its session.
final class SessionWriter {

    let folder: URL
    private let sessionID: String
    private let condition: String
    private let manifest: FileHandle

    /// The columns of manifest.csv: one line per picture.
    static let header = "session,condition,phase,label,variant,frame,time,side,file,"
        + "crop_x,crop_y,crop_side,eye_distance,roll,yaw,frame_w,frame_h"

    init(root: URL, session: String, condition: String) throws {
        sessionID = session
        // The condition is free text typed by you; commas or quotes would break the CSV.
        self.condition = condition
            .components(separatedBy: CharacterSet(charactersIn: ",\"\r\n"))
            .joined(separator: " ")
            .split(separator: " ")
            .joined(separator: " ")

        folder = root.appendingPathComponent(session, isDirectory: true)
        let files = FileManager.default
        for label in [EyeLabel.open, EyeLabel.closed] {
            try files.createDirectory(at: folder.appendingPathComponent(label.rawValue, isDirectory: true),
                                      withIntermediateDirectories: true)
        }

        let manifestURL = folder.appendingPathComponent("manifest.csv")
        try (Self.header + "\n").write(to: manifestURL, atomically: true, encoding: .utf8)
        manifest = try FileHandle(forWritingTo: manifestURL)
        try manifest.seekToEnd()
    }

    /// Saves one eye picture and its manifest line. Returns false when the disk refused.
    @discardableResult
    func save(_ sample: Sample) -> Bool {
        let name = String(format: "p%02d_f%06d_%@.png", sample.phaseIndex, sample.frameIndex, sample.eye.side.rawValue)
        let relative = "\(sample.phase.label.rawValue)/\(name)"
        let url = folder.appendingPathComponent(relative)

        // PNG, not JPEG: PNG keeps every pixel exactly. JPEG throws detail away, and its
        // blocks are plainly visible on a 64x64 picture - the model would learn from them.
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, sample.image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }

        func angle(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        let rect = sample.eye.cropRect
        let fields: [String] = [
            sessionID, condition, String(sample.phaseIndex), sample.phase.label.rawValue, sample.phase.variant,
            String(sample.frameIndex), String(format: "%.3f", sample.time), sample.eye.side.rawValue, relative,
            String(Int(rect.minX)), String(Int(rect.minY)), String(Int(rect.width)),
            String(format: "%.1f", sample.located.interocularDistance),
            angle(sample.located.roll), angle(sample.located.yaw),
            String(Int(sample.frameSize.width)), String(Int(sample.frameSize.height)),
        ]
        guard let line = (fields.joined(separator: ",") + "\n").data(using: .utf8) else { return false }
        do { try manifest.write(contentsOf: line) } catch { return false }
        return true
    }
}

/// The sessions on disk: which is the latest, and how to throw one away.
///
/// A session is one folder, and nothing else refers to it: its pictures and its
/// manifest.csv live inside. So discarding a session is removing ONE folder - never
/// emptying it by hand, which leaves a session with a manifest and no pictures behind.
enum SessionStore {

    /// The most recent session folder. Their names are dates (20261120-101147), so the
    /// last one in alphabetical order is the newest.
    static func latest(in root: URL) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { $0.hasDirectoryPath }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Removes a whole session. `toTrash` puts it in the Trash, where a mistake can still
    /// be undone; without it the folder is deleted for good.
    static func discard(_ folder: URL, toTrash: Bool) throws {
        if toTrash {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: folder)
        }
    }
}

/// How many pictures are on disk, over every session.
struct DatasetStats: Equatable {
    var sessions = 0
    var open = 0
    var closed = 0

    static func scan(_ root: URL) -> DatasetStats {
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
