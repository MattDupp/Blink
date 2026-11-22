import Foundation

/// Who says the setup's spoken lines.
///
/// The app has a voice of its own, because half of a recording is spent with closed eyes.
/// Someone who uses VoiceOver already has a voice, at the speed they chose, and two voices
/// talk over each other: the screen reader reading a page while the app says "close your
/// eyes". So with VoiceOver on, the lines are handed to VoiceOver as announcements and the
/// app's own voice stays silent.
///
/// The app's voice tells when a sentence is finished; VoiceOver does not. The script waits
/// for each line before the pose begins, so the wait is worked out from the sentence.
///
/// NOT VERIFIED BY EAR (22 November 2026): written from the documentation, on a Mac where
/// VoiceOver was off. The rule is tested; nobody has heard the result.
public enum SpokenGuide {

    public enum Channel: Equatable, Sendable {
        /// The app speaks (`Speaker`).
        case ownVoice
        /// VoiceOver is asked to announce the line.
        case voiceOver
    }

    public static func channel(voiceOverOn: Bool) -> Channel {
        voiceOverOn ? .voiceOver : .ownVoice
    }

    /// How long to leave VoiceOver to say `text` before going on.
    ///
    /// 180 words a minute is VoiceOver's pace as installed. People who use it every day
    /// set it faster, and then the pose simply begins a little after the sentence ended,
    /// which costs nothing. Too short a wait would begin the pose under the words.
    public static func seconds(toSay text: String, wordsAMinute: Double = 180) -> Double {
        let words = text.split { $0 == " " || $0 == "\n" }.count
        guard words > 0 else { return 0 }
        // One second at least, and half a second for VoiceOver to start speaking.
        return max(1, Double(words) / wordsAMinute * 60 + 0.5)
    }
}
