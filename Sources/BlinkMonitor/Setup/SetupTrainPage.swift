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
            } else {
                progress
                Samples(model: model)
                Text("What is happening: the model looks at every picture \(model.parts.passes) times. Each time the picture is altered: turned, shifted, darker, blurred. The eyelid is the only thing that stays the same, so that is what it learns to read.")
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
        default: return "Training your model"
        }
    }

    private var fraction: Double {
        switch model.training {
        case .waiting: return 0
        case .reading(let done, let total): return 0.1 * Double(done) / Double(max(total, 1))
        case .learning(let pass, let of, _): return 0.1 + 0.85 * Double(pass) / Double(max(of, 1))
        case .checking: return 0.97
        case .done: return 1
        case .failed: return 0
        }
    }

    private var line: String {
        // A time left that stopped moving is worse than none.
        if model.trainingSilent { return "Still working…" }
        switch model.training {
        case .waiting: return "Starting…"
        case .reading(_, let total): return "Reading your \(total.formatted()) pictures…"
        case .learning(let pass, let of, let left):
            guard let left else { return "Pass \(pass) of \(of). Measuring how long a pass takes on this Mac…" }
            return "Pass \(pass) of \(of). About \(Self.duration(left)) left."
        case .checking: return "Checking the finished model…"
        case .done: return result
        case .failed: return ""
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

// MARK: - Test
