import SwiftUI
import ServiceManagement
import BlinkCore

/// Whether macOS starts the app at login (System Settings > General > Login Items).
@MainActor
final class LoginItem: ObservableObject {

    @Published private(set) var enabled = false
    @Published private(set) var problem: String?

    /// Only a real app (a bundle) can be a login item - and the demo should not become one.
    let available: Bool

    init(allowed: Bool = true) {
        available = allowed && Bundle.main.bundleIdentifier != nil
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
