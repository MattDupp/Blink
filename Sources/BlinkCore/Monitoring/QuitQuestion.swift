import Foundation

/// Should the app ask before it quits, and what does it say?
///
/// Quit was immediate in every case. Three of them cost something a person cannot see
/// coming: a timer whose end sound will never play for someone with covered eyes, a
/// recording that is lost, a training that stops. In every other case quitting is still
/// immediate: an app that always asks teaches people to press Return without reading.
public enum QuitQuestion {

    public struct Facts: Equatable, Sendable {
        /// The routine whose timer is running, by its title.
        public var timer: String?
        /// The setup is recording eyes.
        public var recording = false
        /// The setup is training a model.
        public var training = false

        public init(timer: String? = nil, recording: Bool = false, training: Bool = false) {
            self.timer = timer
            self.recording = recording
            self.training = training
        }
    }

    public struct Question: Equatable, Sendable {
        public var title: String
        public var text: String
    }

    /// Nil: nothing would be lost, quit at once.
    public static func question(_ facts: Facts) -> Question? {
        if let timer = facts.timer {
            return Question(title: "A timer is running",
                            text: "Quitting stops the timer of \(timer). No sound will mark its end, and it will not be marked done.")
        }
        if facts.recording {
            return Question(title: "A recording is in progress",
                            text: "Quitting now loses this recording. The ones already saved stay.")
        }
        if facts.training {
            return Question(title: "Your model is being trained",
                            text: "Quitting stops the training. Your recordings stay, and the training starts again when you come back.")
        }
        return nil
    }
}
