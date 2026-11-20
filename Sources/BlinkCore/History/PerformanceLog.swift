import Foundation

/// One line a minute about the pipeline's own cost, in
/// ~/Library/Application Support/BlinkMonitor/performance.csv.
///
/// It answers "what does the app cost on this Mac, hour after hour?" with numbers from
/// real use, not from a benchmark.
public struct PerformanceLog {

    public let file: URL

    public init(file: URL = HistoryStore.applicationFolder.appendingPathComponent("performance.csv")) {
        self.file = file
        // A fresh log when it grows past about a month of minutes.
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 3_000_000 {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func append(_ summary: StageTimings.Summary, at date: Date = Date()) {
        let line = String(format: "%@,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f\n",
                          ISO8601DateFormatter().string(from: date), summary.framesPerSecond, summary.analysedShare,
                          summary.findEyes, summary.crop, summary.model, summary.total, summary.worstTotal)
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "time,frames_per_second,analysed_share,find_eyes_ms,crop_ms,model_ms,frame_ms,worst_frame_ms\n"
                    .write(to: file, atomically: true, encoding: .utf8)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            Log.storage.error("Performance log not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
