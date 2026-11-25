import AppKit
import BlinkCore

/// "Export…" in History: asks for a folder, copies the records there (`KeptRecord`,
/// `DataExport`), and shows the copies in Finder. "Show Data File" was the only way to
/// one's own numbers: it opened the app's folder on one of the files.
@MainActor
enum ExportPanel {

    static func message(_ records: [KeptRecord]) -> String {
        "Copies \(KeptRecord.names(records)) into the folder you choose: files any spreadsheet opens. "
            + "They hold numbers, times and words, no picture. Nothing is sent anywhere."
    }

    static func run(_ records: [KeptRecord]) {
        let panel = NSOpenPanel()
        panel.title = "Export"
        panel.message = message(records)
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let copies = try DataExport.copy(records.map(\.exportItem), to: folder)
            if !copies.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(copies) }
        } catch {
            let alert = NSAlert()
            alert.messageText = "The files could not be copied there"
            alert.informativeText = "Choose another folder, such as Documents. Your history itself is untouched."
            alert.runModal()
        }
    }
}
