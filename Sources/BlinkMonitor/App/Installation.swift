import Foundation

/// Where this copy of the app runs from, and which copy runs when there are two.
///
/// The app reaches people as a disk image: a window with the app next to a shortcut to
/// Applications (`make dmg`). Nothing makes anyone drag before double-clicking, and
/// nothing stops a second copy from being installed next to the first. So the app looks
/// at where it is when it starts, and says so when that is the wrong place.
enum Installation {

    // MARK: The disk image

    /// The app runs from a place it cannot stay in: its disk image, or the hidden
    /// read-only copy macOS runs a downloaded app from until Finder has moved it
    /// ("translocation"). Both are read-only disks, and Applications is not: that is how
    /// they are told apart.
    ///
    /// It works there, for a look. But the disk goes away when it is ejected, and macOS
    /// would be told to start at login an app that is no longer there.
    static let isOnDiskImage = isOnReadOnlyVolume(Bundle.main.bundleURL)

    static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    // MARK: One running copy

    /// What a copy that starts does about the copies already running.
    enum Start: Equatable {
        /// Nobody else: start.
        case alone
        /// Another copy, installed somewhere else, is running. It keeps running and is
        /// asked to show its panel; the copy that just started quits. Two would mean two
        /// eyes in the menu bar and the camera read twice.
        case yielding
        /// What is running was started from this same file, and macOS started this one
        /// all the same: it is an older build, still in memory after the app was replaced
        /// on disk. It is asked to quit and this one takes its place, or the update would
        /// only show after a quit nobody knows they have to do.
        /// The same when what is running sits on a disk image and this copy does not.
        case replacing
    }

    /// `own`: where this copy is. `running`: where each other running copy is (nil for a
    /// bare program, which has no app around it). `onReadOnlyDisk` says whether a place is
    /// a disk image (handed in, so that the tests need no disk image).
    static func start(own: URL, running: [URL?],
                      onReadOnlyDisk: (URL) -> Bool = isOnReadOnlyVolume) -> Start {
        if running.isEmpty { return .alone }
        let here = own.standardizedFileURL.path
        if running.allSatisfy({ $0?.standardizedFileURL.path == here }) { return .replacing }
        // Someone opened the app inside its disk image, was told to drag it to
        // Applications, did, and opened that copy without quitting the first. The
        // installed copy is the one that must stay: the other goes away with its disk.
        // (The first version made the new copy quit, and the panel went on saying
        // "Running from the disk image".)
        if !onReadOnlyDisk(own), running.allSatisfy({ $0.map(onReadOnlyDisk) ?? false }) { return .replacing }
        return .yielding
    }

    /// The name under which a copy that gives way asks the running one to show its panel.
    /// It carries the app's identifier: the demo and the real app do not hear each other.
    static func showPanelRequest(identifier: String) -> Notification.Name {
        Notification.Name("\(identifier).show-panel")
    }
}
