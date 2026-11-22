import SwiftUI
import ServiceManagement
import BlinkCore

/// Whether macOS starts the app at login (System Settings > General > Login Items).
@MainActor
final class LoginItem: ObservableObject {

    @Published private(set) var enabled = false
    @Published private(set) var problem: String?

    /// Why the switch cannot be used here, said under it (nil: it can).
    let unavailable: String?
    var available: Bool { unavailable == nil }

    /// Only a real app (a bundle) can be a login item, and the demo should not become one.
    /// Nor should a copy that runs from its disk image: macOS would remember a place that
    /// is gone as soon as the disk is ejected.
    init(demo: Bool = false, onDiskImage: Bool = Installation.isOnDiskImage) {
        if demo || Bundle.main.bundleIdentifier == nil {
            unavailable = "Not in the demo."
        } else if onDiskImage {
            unavailable = "Not from the disk image: drag Blink Monitor onto Applications and open it from there."
        } else {
            unavailable = nil
        }
    }

    func refresh() {
        guard available else { return }
        enabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ on: Bool) {
        guard available else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch {
            problem = "macOS refused: \(error.localizedDescription)"
            Log.app.error("Login item: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
