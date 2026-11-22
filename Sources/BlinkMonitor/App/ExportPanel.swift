import AppKit
import BlinkCore

/// "Export…" in History: asks for a folder, copies the two files of numbers there
/// (`DataExport`), and shows the copies in Finder. "Show Data File" was the only way to
/// one's own numbers: it opened the app's folder on one of the two files.
@MainActor
enum ExportPanel {

    static let message = "Copies your history and your routine log into the folder you choose: two files any spreadsheet opens. "
        + "They hold numbers and times, no picture. Nothing is sent anywhere."

    static func run(history: URL, routineLog: URL) {
        let panel = NSOpenPanel()
        panel.title = "Export"
        panel.message = message
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let copies = try DataExport.copy(DataExport.items(history: history, routineLog: routineLog), to: folder)
            if !copies.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(copies) }
        } catch {
            let alert = NSAlert()
            alert.messageText = "The files could not be copied there"
            alert.informativeText = "Choose another folder, such as Documents. Your history itself is untouched."
            alert.runModal()
        }
    }
}
