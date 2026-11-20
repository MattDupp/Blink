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
        do {
            try CSVAppender(url: file, header: Self.header).append([
                ISO8601DateFormatter().string(from: date),
                String(format: "%.1f", summary.framesPerSecond), String(format: "%.2f", summary.analysedShare),
                String(format: "%.2f", summary.findEyes), String(format: "%.2f", summary.crop),
                String(format: "%.2f", summary.model), String(format: "%.2f", summary.total),
                String(format: "%.1f", summary.worstTotal),
            ])
        } catch {
            Log.storage.error("Performance log not opened: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let header = "time,frames_per_second,analysed_share,find_eyes_ms,crop_ms,model_ms,frame_ms,worst_frame_ms"
}
