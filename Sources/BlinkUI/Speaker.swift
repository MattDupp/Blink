import AVFoundation
import AppKit
import BlinkCore

/// Says the instructions aloud. Half of every session is spent with your eyes closed,
/// so the screen alone cannot guide you.
@MainActor
public final class Speaker: NSObject, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private var waiting: CheckedContinuation<Void, Never>?
    private var generation = 0

    /// The best English voice installed. The default one is the oldest and the flattest;
    /// many Macs also carry an "enhanced" or "premium" one, and it is the guide for two
    /// minutes with closed eyes. American English first, since the script is written in it.
    static let voice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            voice.quality.rawValue * 2 + (voice.language == "en-US" ? 1 : 0)
        }
        // Novelty voices ("Bells", "Zarvox") are of default quality: an American default
        // voice is only taken from the system's own choice.
        let better = english.filter { $0.quality != .default }.max { rank($0) < rank($1) }
        return better ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Whether VoiceOver is running, asked each time: it can be switched on mid-recording.
    /// (A closure, so that a test can state it.)
    public var voiceOverOn: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }

    /// Speaks, and returns when the sentence is finished.
    public func say(_ text: String) async {
        // With VoiceOver on, VoiceOver says the line and this voice keeps silent: two
        // voices talked over each other (`SpokenGuide`).
        if SpokenGuide.channel(voiceOverOn: voiceOverOn()) == .voiceOver {
            generation += 1
            let mine = generation
            // High priority: said now, before whatever VoiceOver was reading.
            NSAccessibility.post(element: NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any,
                                 notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            let end = Date().addingTimeInterval(SpokenGuide.seconds(toSay: text))
            // In short steps, so that `stop` (which moves `generation` on) ends the wait.
            while Date() < end, generation == mine {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        generation += 1
        let mine = generation

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting = continuation
            synthesizer.speak(utterance)
            // Safety net: if the system never reports the end of the sentence (no voice
            // installed, sound device gone), the session must not wait forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                Task { @MainActor in
                    if let self, self.generation == mine { self.finish() }
                }
            }
        }
    }

    public func stop() {
        generation += 1                 // ends the wait for a VoiceOver announcement
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        waiting?.resume()
        waiting = nil
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
