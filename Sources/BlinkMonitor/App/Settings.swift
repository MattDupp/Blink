import Foundation

/// The few choices the app remembers between launches, each under one name, in one place.
///
/// They are stored by macOS's UserDefaults (a small per-app file). Going through this type
/// means a key is spelled once, and that a test or a screenshot can be given a store of
/// its own instead of the user's real settings.
struct Settings {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An empty store that is never the user's: for screenshots.
    static func temporary() -> Settings {
        let name = "local.blinkmonitor.temporary"
        UserDefaults().removePersistentDomain(forName: name)
        return Settings(defaults: UserDefaults(suiteName: name) ?? .standard)
    }

    /// "Blinking too little" starts under this many blinks a minute. People at rest blink
    /// roughly 15 to 20 times a minute, and far less when staring at a screen; 10 is a
    /// starting point for you to adjust, not a medical limit.
    var threshold: Int {
        get { defaults.object(forKey: "threshold") as? Int ?? 10 }
        nonmutating set { defaults.set(newValue, forKey: "threshold") }
    }

    var remindersOn: Bool {
        get { defaults.object(forKey: "remindersOn") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "remindersOn") }
    }

    /// The Welcome window has been seen.
    var welcomed: Bool {
        get { defaults.bool(forKey: "welcomed") }
        nonmutating set { defaults.set(newValue, forKey: "welcomed") }
    }
}
