import Foundation

/// "Delete Everything and Quit": what the app leaves on a Mac, removed in one go.
///
/// Dragging the app to the Trash leaves its folder behind: pictures of eyes, a model
/// trained on them, the history, the routine log. Removing them was explained on GitHub
/// only. This is that explanation as one button.
///
/// It takes the folder and the settings it is handed, so that a test can give it a
/// temporary folder and a settings store of its own. It is never to be run against the
/// real ones from a test.
public enum Uninstall {

    /// Removes `folder` with everything in it, and every setting stored under `domain`.
    /// A folder that does not exist is not an error: there is then nothing to remove.
    public static func deleteEverything(folder: URL, defaults: UserDefaults, domain: String?) throws {
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        if let domain {
            defaults.removePersistentDomain(forName: domain)
            defaults.synchronize()
        }
    }
}
