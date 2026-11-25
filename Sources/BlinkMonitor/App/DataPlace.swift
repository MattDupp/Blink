import Foundation
import BlinkCore

/// Where a model's files are: the user's own, or a scratch folder of its own.
///
/// THE USER'S OWN FILES ARE ASKED FOR BY NAME: the app asks for `.real` (`Entry`), and a
/// model gets a scratch folder when nobody says. Before, a made-up model (the demo, the
/// screenshots) had scratch files for three of its records, while the history and the
/// trained model stayed the user's own unless each was named; a model made without a
/// made-up state even opened the real routine log. A test that forgot one name would have
/// written to, or erased, the user's history.
///
/// Each scratch folder is new. The demo, the screenshots and `swift test` used to share
/// fixed names in the temporary folder, and running two of them emptied the other's files.
struct DataPlace {
    let folder: URL

    /// The app's own folder: ~/Library/Application Support/BlinkMonitor.
    static var real: DataPlace { DataPlace(folder: HistoryStore.applicationFolder) }

    /// A new folder in the temporary folder, for made-up data. macOS clears it after a few days.
    static func scratch() -> DataPlace {
        DataPlace(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-scratch-\(UUID().uuidString)", isDirectory: true))
    }

    var history: HistoryStore { HistoryStore(in: folder) }
    var care: CareStore { CareStore(in: folder) }
    var eyeNotes: EyeNoteStore { EyeNoteStore(in: folder) }
    var routines: RoutineStore { RoutineStore(in: folder) }
    var models: ModelStore { ModelStore(base: folder) }
    /// Where the setup records its sessions.
    var sessions: URL { folder.appendingPathComponent("sessions", isDirectory: true) }
}
