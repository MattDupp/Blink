import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The training page: progress, the altered pictures, and a failure said in a sentence.

/// What a failed training is called, in a sentence for a person. The trainer's own
/// words (a signal number, an assertion) go to the log and to "Copy the Details".
enum TrainingFailureWords {
    static func plain(_ reason: String) -> String {
        if reason.hasPrefix("The training program stopped before the end") { return "The training program stopped unexpectedly." }
        if reason.hasPrefix("The training program stopped answering") { return "The training stopped making progress, and was ended." }
        if reason.hasPrefix("The training program could not be started") { return "The training program could not be started." }
        if reason.hasPrefix("The model's folder could not be prepared") || reason.hasPrefix("The trained model could not be put in place") {
            return "The model could not be written to disk."
        }
        // What the training said itself is already a sentence (too few pictures, a check
        // that failed): its first line.
        return reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? "The training stopped."
    }

    static let advice = "Quit apps that work the graphics processor hard (games, video editing), or restart the Mac, then try again."
    /// Where a problem is reported. The browser opens it: the app itself connects to nothing.
    static let reportPage = URL(string: "https://github.com/MattDupp/Blink/issues/new")
}

struct TrainPage: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title, "It happens on this Mac, from your own pictures. Nothing is sent anywhere.")
            if case .failed(let reason, let attempts) = model.training {
                failure(reason: reason, attempts: attempts)
            } else if case .flagged(let flags) = model.training {
                FlaggedPoses(model: model, flags: flags)
            } else {
                progress
                Samples(model: model)
                Text(explanation)
                    .textStyle(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Spacer()
                if case .failed = model.training {
                    Button("Try Again") { model.retryTraining() }
                        .mainButton()
                        .controlSize(.large)
                } else if case .flagged(let flags) = model.training {
                    Button(PoseFlagWords.leaveOut(flags.count)) { model.leaveOut() }
                        .controlSize(.large)
                        .help(PoseFlagWords.leaveOutHelp)
                    Button(PoseFlagWords.recordAgain(flags.count)) { model.recordAgain() }
                        .mainButton()
                        .controlSize(.large)
                } else {
                    Button("Test It") { model.beginProof() }
                        .mainButton()
                        .controlSize(.large)
                        .disabled(model.training != .done)
                }
            }
        }
    }

    private var title: String {
        switch model.training {
        case .done: return "Your model is trained"
        case .failed: return "The training stopped"
        case .flagged(let flags): return PoseFlagWords.title(flags.count)
        default: return "Training your model"
        }
    }

    private var explanation: String {
        if case .checkingPoses = model.training {
            return "What is happening: each pose is shown to a model that did not learn from it. A pose it reads the other way, without doubt, is one where the eyes did not do what the voice asked. Nothing is learned from your pictures before this."
        }
        return "What is happening: the model looks at every picture \(model.parts.passes) times. Each time the picture is altered: turned, shifted, darker, blurred. The eyelid is the only thing that stays the same, so that is what it learns to read."
    }

    private var fraction: Double {
        // When the poses are checked first, the check takes the bar's first half.
        let learningFrom = model.posesChecked ? 0.55 : 0.1
        switch model.training {
        case .waiting: return 0
        case .reading(let done, let total): return 0.1 * Double(done) / Double(max(total, 1))
        case .checkingPoses(let done, let of): return 0.1 + 0.45 * Double(done) / Double(max(of, 1))
        case .learning(let pass, let of, _): return learningFrom + (0.95 - learningFrom) * Double(pass) / Double(max(of, 1))
        case .checking: return 0.97
        case .done: return 1
        case .failed, .flagged: return 0
        }
    }

    private var line: String {
        // A time left that stopped moving is worse than none.
        if model.trainingSilent { return "Still working…" }
        switch model.training {
        case .waiting: return "Starting…"
        case .reading(_, let total): return "Reading your \(total.formatted()) pictures…"
        case .checkingPoses: return "Checking that each pose was held as the voice asked…"
        case .learning(let pass, let of, let left):
            guard let left else { return "Pass \(pass) of \(of). Measuring how long a pass takes on this Mac…" }
            return "Pass \(pass) of \(of). About \(Self.duration(left)) left."
        case .checking: return "Checking the finished model…"
        case .done: return result
        case .failed, .flagged: return ""
        }
    }

    /// What the training produced, in numbers a person can check.
    private var result: String {
        guard let info = model.info else { return "Done." }
        return "Trained on \(info.pictures.formatted()) pictures from \(Format.count(info.sessions.count, "recording")) "
            + "in \(Self.duration(info.seconds)). "
            + "Shown the same pictures again, unaltered, it calls \(info.rightOnOwnPictures.formatted()) of them right. "
            + "That is the easy test, since it has seen them. The real one is next."
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(max(1, Int(seconds.rounded()))) s" : "\(Int((seconds / 60).rounded())) min"
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: fraction)
                .tint(model.training == .done ? .green : .accentColor)
                .animation(.easeOut(duration: 0.3), value: fraction)
            Text(line)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failure(reason: String, attempts: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 8) {
                Text(attempts < 2 ? "It stopped before the end" : "It stopped again").textStyle(.headline)
                Text(TrainingFailureWords.plain(reason))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your recordings are kept, and no half-made model was installed. "
                     + (attempts < 2 ? "Trying again is usually enough." : TrainingFailureWords.advice))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The first failure may be a passing one. After a second, there must be
                // somewhere to take it: the details to copy, and a place to report them.
                if attempts >= 2 {
                    HStack(spacing: 10) {
                        Button("Copy the Details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reason, forType: .string)
                        }
                        if let page = TrainingFailureWords.reportPage {
                            Button("Report It") { NSWorkspace.shared.open(page) }
                                .help("Opens the project's page in your browser. Blink itself sends nothing.")
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A few of your own pictures, as this pass shows them to the model.
private struct Samples: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        if !model.alteredSamples.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(Array(model.alteredSamples.enumerated()), id: \.offset) { _, image in
                        EyeThumbnail(image: image, side: 101)
                    }
                }
                Text(caption)
                    .textStyle(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String {
        if case .learning = model.training { return "Six of your pictures, as the model is shown them during this pass." }
        return "Six of your pictures: three with the eyes open, three closed."
    }
}

/// What is said of a pose held the wrong way (`PoseCheck`), on the training page and on the
/// recording page: one place for these sentences.
enum PoseFlagWords {

    static func title(_ count: Int) -> String {
        count == 1 ? "One pose needs another try" : "\(Format.word(count).capitalized) poses need another try"
    }

    /// "Recording 2, pose 16: “Close your eyes. Keep your head tilted.”"
    static func place(_ flag: PoseFlag, recording: Int?) -> String {
        let instruction = SessionScript.phases.indices.contains(flag.phase)
            ? SessionScript.phases[flag.phase].instruction
            : (flag.label == .open ? "Eyes open." : "Close your eyes.")
        return "Recording \(recording ?? 1), pose \(flag.phase + 1): “\(instruction)”"
    }

    /// What the check saw, and what a model would learn from it.
    static func seen(_ flag: PoseFlag) -> String {
        flag.label == .closed
            ? "In its \(flag.pictures.formatted()) pictures the eyes look open. A model that learned from them would read open eyes as closed, and count blinks that did not happen."
            : "In its \(flag.pictures.formatted()) pictures the eyes look closed. A model that learned from them would read closed eyes as open, and miss blinks."
    }

    static let how = "How this is known: each pose was shown to a model that had not learned from it, and it read this one the other way without doubt. Nothing has been learned from your pictures yet."

    static func recordAgain(_ count: Int) -> String { count == 1 ? "Record It Again" : "Record Them Again" }
    static func leaveOut(_ count: Int) -> String { count == 1 ? "Leave It Out" : "Leave Them Out" }
    static let leaveOutHelp = "The training goes on without those pictures. They are kept aside in the recording's folder, not deleted."
}

/// The poses held the wrong way, each with what was seen in it.
private struct FlaggedPoses: View {
    @ObservedObject var model: SetupModel
    let flags: [PoseFlag]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(flags.enumerated()), id: \.offset) { _, flag in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PoseFlagWords.place(flag, recording: model.recordingNumber(of: flag)))
                            .textStyle(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(PoseFlagWords.seen(flag))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(PoseFlagWords.how)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Test
