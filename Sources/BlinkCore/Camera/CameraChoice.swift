import Foundation

/// A camera this Mac offers.
public struct CameraOption: Equatable, Identifiable, Sendable {
    /// What macOS knows it by. Stored when the user chooses it.
    public let id: String
    /// As macOS names it: "FaceTime HD Camera", "Studio Display Camera".
    public let name: String
    /// The Mac's own camera, in its lid or its screen.
    public let builtIn: Bool

    public init(id: String, name: String, builtIn: Bool) {
        self.id = id
        self.name = name
        self.builtIn = builtIn
    }
}

/// Where the camera in use sits, for the words about it: "open the lid" means nothing on
/// a Mac mini, nor when the camera is a webcam on a stand.
public enum CameraPlace: Equatable, Sendable {
    /// In the lid of a portable Mac: closing the lid hides it.
    case lid
    /// In the screen of a desktop Mac.
    case screen
    /// A camera of its own, plugged in or in an external display.
    case separate

    /// `builtIn`: whether the camera in use is the Mac's own; nil when none is known, and
    /// then the Mac's own is assumed where there is a lid, since that is what Automatic takes.
    public init(builtIn: Bool?, macHasLid: Bool) {
        switch (builtIn, macHasLid) {
        case (false, _): self = .separate
        case (true, true), (nil, true): self = .lid
        case (true, false): self = .screen
        case (nil, false): self = .separate
        }
    }
}

/// Which camera the app uses.
///
/// The app always took the Mac's own. Docked with the lid closed and an external webcam,
/// that camera sends nothing, and the app said "No picture" for ever with the working
/// camera beside it. Now there is a choice, and AUTOMATIC, the default, behaves as before
/// plus one thing: after ten seconds without a picture it moves to another camera.
///
/// A camera the user chose is never left by itself: a choice is a choice.
public enum CameraChoice {

    /// Automatic moves to another camera after this long without a picture.
    public static let silenceBeforeFallback = 10.0

    /// The camera to start with. `wanted`: the stored choice, nil for Automatic. A chosen
    /// camera that is no longer there (unplugged) falls back to the automatic pick.
    public static func pick(from options: [CameraOption], wanted: String?) -> CameraOption? {
        if let wanted, let chosen = options.first(where: { $0.id == wanted }) { return chosen }
        return options.first { $0.builtIn } ?? options.first
    }

    /// Automatic only: the camera to move to, when the one in use has sent nothing for
    /// `silentSeconds`. Nil: stay. `tried`: the cameras already tried during this silence,
    /// so that the app goes round them once and does not swap for ever in the dark.
    public static func fallback(from options: [CameraOption], current: String?, wanted: String?,
                                silentSeconds: Double, tried: Set<String> = []) -> CameraOption? {
        guard wanted == nil, silentSeconds >= silenceBeforeFallback else { return nil }
        return options.first { $0.id != current && !tried.contains($0.id) }
    }
}
