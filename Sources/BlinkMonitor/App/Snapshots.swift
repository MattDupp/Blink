import AppKit
import SwiftUI
import BlinkCore

/// Renders every screen of the app to a PNG, with made-up data:
///
///     BlinkMonitor --snapshots=<folder>          (or: make snapshots)
///
/// Two uses. While designing: a screen can be looked at, changed and looked at again
/// without clicking through the app. For the README: screenshots that are always up to
/// date and never show anyone's face (the camera is not opened).
@MainActor
enum Snapshots {

    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("Cannot create \(folder.path): \(error.localizedDescription)")
            return false
        }

        // A fixed moment (a Friday afternoon), so the pictures do not change from day to day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 16, minute: 42)) ?? Date()

        var written = 0
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let normal = MonitorModel()
            normal.loadSample(now: now)
            let low = MonitorModel()
            low.loadSample(now: now, low: true)

            let screens: [(String, AnyView)] = [
                ("panel", AnyView(MenuPanelView(model: normal, history: normal.history, reminders: normal.reminders,
                                               loginItem: normal.loginItem, now: now, actions: PanelActions()))),
                ("panel-low", AnyView(MenuPanelView(model: low, history: low.history, reminders: low.reminders,
                                                   loginItem: low.loginItem, now: now, actions: PanelActions()))),
                ("history", AnyView(HistoryView(history: normal.history, reminders: normal.reminders, now: now))),
                ("welcome", AnyView(WelcomeView(start: {}))),
                ("diagnostics", AnyView(DiagnosticsView(model: normal, captures: normal.captures))),
            ]
            for (name, view) in screens {
                let file = folder.appendingPathComponent("\(name)-\(suffix).png")
                if write(view, appearance: appearance, to: file) {
                    written += 1
                    print("Wrote \(file.path)")
                } else {
                    print("FAILED \(file.lastPathComponent)")
                }
            }
        }
        return written == 10
    }

    /// Lays a view out off screen, at twice the resolution, and saves it.
    private static func write(_ view: AnyView, appearance name: NSAppearance.Name, to file: URL) -> Bool {
        let appearance = NSAppearance(named: name)
        let framed = view
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(18)

        let hosting = NSHostingView(rootView: framed)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)

        // The view has to live in a window to be drawn with its controls.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))   // let SwiftUI finish its first pass

        let scale = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                            pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return false }
        return PNGFile.write(image, to: file)
    }
}
