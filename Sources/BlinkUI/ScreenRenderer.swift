import AppKit
import SwiftUI
import BlinkCore

/// Draws a window's content to a PNG without showing it: how the app makes its own
/// screenshots (`--snapshots=<folder>`), with made-up data and the camera never opened.
///
/// Two uses. While designing: a screen can be looked at, changed and looked at again
/// without clicking through the app. For the README: screenshots that are always up to
/// date and never show anyone's face.
@MainActor
public enum ScreenRenderer {

    /// Renders every screen in light and in dark, as `<name>-light.png` and `<name>-dark.png`.
    /// `screens` is asked once per appearance, so that each picture starts from a fresh state.
    public static func render(to folder: URL, screens: () -> [(name: String, view: AnyView)]) -> Bool {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("Cannot create \(folder.path): \(error.localizedDescription)")
            return false
        }
        var failed = 0
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, view) in screens() {
                let file = folder.appendingPathComponent("\(name)-\(suffix).png")
                if write(view, appearance: appearance, to: file) {
                    print("Wrote \(file.path)")
                } else {
                    failed += 1
                    print("FAILED \(file.lastPathComponent)")
                }
            }
        }
        return failed == 0
    }

    /// Lays a view out off screen, at twice the resolution, and saves it.
    private static func write(_ view: AnyView, appearance name: NSAppearance.Name, to file: URL) -> Bool {
        let appearance = NSAppearance(named: name)
        let framed = view
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(18)
            // A picture shows the whole window, on whatever Mac it is rendered: the room
            // of this Mac's screen must not cut it (`ScrollsWhenTall`). A screen that
            // wants to show the scrolling states a room of its own, further in.
            .environment(\.screenRoom, ScreenRoom.unlimited)

        let hosting = NSHostingView(rootView: framed)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)

        // The view has to live in a window to be drawn with its controls.
        // (A window that is never shown is never "in front", so macOS draws its switches
        // grey even when they are on: in the pictures, read a switch by its knob's side.)
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
