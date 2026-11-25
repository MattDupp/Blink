import Foundation
import BlinkCore

/// One training, run away from the app's windows.
///
/// In the app it starts a HELPER PROCESS: the app's own program, launched a second time
/// with `--train`, which does nothing but train and print its progress, one line each
/// (`TrainingRun.helper`). The training runs inside Apple's graphics frameworks, and a
/// failed assertion there ends the process it happens in (seen once: `EyeTrainer.run`).
/// In a helper that is one training to start again, with the reason at hand; inside the
/// app it would be the app gone, in the middle of its setup.
///
/// The tests have no app to launch a second time: there, the same training runs on a
/// background queue of the test process (`Way.inProcess`).
@MainActor
final class TrainingJob {

    enum Way {
        /// Launch this program again with `--train`.
        case helper(URL)
        case inProcess

        /// A helper when this process is the app itself; in the tests, the process is the
        /// test runner, which cannot be asked to train.
        static var usual: Way {
            guard let program = Bundle.main.executableURL, program.lastPathComponent == "BlinkMonitor" else { return .inProcess }
            return .helper(program)
        }
    }

    /// No word from the helper for this long: it is ended, and the training has failed.
    static let silenceAllowed = 120.0

    private let way: Way
    private let sessions: URL
    private let staging: URL
    private let passes: Int
    private let report: (TrainingProgress) -> Void

    private var process: Process?
    /// The helper's two outputs, read line by line until it closes them (`PipeLines`).
    private var readers: [PipeLines] = []
    private var over = false
    private var silence: Timer?
    private var complaints: [String] = []

    /// One of the helper's outputs is still being read (the tests ask).
    var isReading: Bool { readers.contains(where: \.isReading) }

    /// `report` is called on the main thread; its last call is `.finished` or `.failed`.
    init(way: Way = .usual, sessions: URL, staging: URL, passes: Int = TrainingRun.passes,
         report: @escaping (TrainingProgress) -> Void) {
        self.way = way
        self.sessions = sessions
        self.staging = staging
        self.passes = passes
        self.report = report
    }

    func start() {
        switch way {
        case .inProcess:
            let (sessions, staging, passes) = (sessions, staging, passes)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                TrainingRun.run(sessions: sessions, into: staging, passes: passes) { progress in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(progress) } }
                }
            }
        case .helper(let program):
            launch(program)
        }
    }

    /// Ends the training. Nothing more is reported.
    func cancel() {
        over = true
        silence?.invalidate()
        process?.terminate()
        process = nil
        readers.forEach { $0.stop() }
    }

    private func launch(_ program: URL) {
        let process = Process()
        process.executableURL = program
        process.arguments = ["--train", "--sessions-dir=\(sessions.path)", "--model-out=\(staging.path)", "--passes=\(passes)"]
        // The pipes are read on a background queue; everything else happens on the main one.
        let output = PipeLines { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.read(line) } }
        }
        let errors = PipeLines { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.complaints.append(line) } }
        }
        readers = [output, errors]
        process.standardOutput = output.pipe
        process.standardError = errors.pipe
        process.terminationHandler = { [weak self] ended in
            let (reason, code) = (ended.terminationReason, ended.terminationStatus)
            // A moment later: the last lines may still be on their way through the pipe.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { self?.ended(crashed: reason == .uncaughtSignal, code: code) }
            }
        }
        do {
            try process.run()
            self.process = process
            listenForSilence()
        } catch {
            received(.failed("The training program could not be started: \(error.localizedDescription)"))
        }
    }

    private func read(_ line: String) {
        if let progress = TrainingProgress(line: line) { received(progress) }
    }

    private func received(_ progress: TrainingProgress) {
        guard !over else { return }
        switch progress {
        case .finished, .failed:
            over = true
            silence?.invalidate()
        case .reading, .learning, .checking:
            listenForSilence()
        }
        report(progress)
    }

    /// The helper has ended. If it never said how, it was cut short: say what is known.
    private func ended(crashed: Bool, code: Int32) {
        // The helper is gone: whatever its pipes still hold was read in the 0.3 s before this.
        readers.forEach { $0.stop() }
        guard !over else { return }
        let last = complaints.suffix(3).joined(separator: "\n")
        Log.app.error("Trainer ended early (code \(code, privacy: .public)): \(last, privacy: .public)")
        received(.failed("The training program stopped before the end (\(crashed ? "signal" : "code") \(code))."
                         + (last.isEmpty ? "" : "\n\(last)")))
    }

    private func listenForSilence() {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: Self.silenceAllowed, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.over else { return }
                self.process?.terminate()
                self.process = nil
                self.received(.failed("The training program stopped answering, and was ended."))
            }
        }
    }
}
