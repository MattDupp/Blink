import SwiftUI
import AppKit
import BlinkCore

/// Records every frame for a while, for study and for training (Live View window).
@MainActor
final class CaptureController: ObservableObject {

    /// Set while a capture is running: what to do, shown in the window.
    @Published private(set) var instruction: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var result: String?

    /// A cued capture: one tick every 1.5 s, 20 times. You blink once at each tick, so
    /// the 30 seconds hold a known number of blinks, at roughly known moments.
    static let cueCount = 20
    static let cueSeconds = 1.5
    static let freeSeconds = 60.0

    var isCapturing: Bool { instruction != nil }

    private let tickSound = NSSound(named: "Tink")
    private var task: Task<Void, Never>?

    /// `cued`: with ticks to blink on; otherwise you carry on and natural blinks are recorded.
    /// `wholeFrames`: also keep the whole camera picture of every frame (`CaptureWriter`).
    func start(cued: Bool, pipeline: MonitorPipeline, root: URL, wholeFrames: Bool = false) {
        guard !isCapturing else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = formatter.string(from: Date()) + (cued ? "-cued" : "-free")

        let writer: CaptureWriter
        do {
            writer = try CaptureWriter(root: root, name: name, wholeFrames: wholeFrames)
        } catch {
            result = "The capture folder could not be created: \(error.localizedDescription)"
            return
        }

        result = nil
        progress = 0
        instruction = cued
            ? "Blink ONCE at each tick - quick, light blinks, like the ones that get missed."
            : "Carry on normally (read, type). Your natural blinks are being recorded."
        if wholeFrames { instruction? += " The whole camera picture is being kept." }
        let total = cued ? Double(Self.cueCount) * Self.cueSeconds : Self.freeSeconds

        task = Task {
            pipeline.setCapture(writer)
            withAnimation(.linear(duration: total)) { progress = 1 }
            if cued {
                // Half a second of calm first, then the ticks.
                try? await Task.sleep(nanoseconds: 500_000_000)
                for _ in 0..<Self.cueCount {
                    (tickSound?.copy() as? NSSound)?.play()
                    pipeline.markTick()
                    try? await Task.sleep(nanoseconds: UInt64(Self.cueSeconds * 1_000_000_000))
                }
            } else {
                try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
            }
            pipeline.setCapture(nil)
            // The movie of whole frames is whole only once it is closed.
            let closed = await writer.finish()
            instruction = nil
            progress = 0
            if !writer.keepsWholeFrames {
                result = "Saved \(writer.frames) frames in \(writer.folder.path)"
            } else if closed {
                result = "Saved \(writer.frames) frames, and the whole picture of \(writer.wholeFrames) of them, in \(writer.folder.path)"
            } else {
                result = "Saved \(writer.frames) frames in \(writer.folder.path) - but the whole pictures could not be kept."
            }
        }
    }
}
