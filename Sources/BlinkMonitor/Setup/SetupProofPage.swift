import SwiftUI
import AppKit
import BlinkCore
import BlinkUI

// The test page: ten ticks, a blink at each, and what the result means.

struct ProofPage: View {
    @ObservedObject var model: SetupModel
    let actions: SetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle("Test it: blink, and watch it count",
                      "The real test: blink \(Format.word(ProofTest.ticks)) times and see how many it counts.")
            // The same card as on the camera and recording pages: a grey Start button
            // with no reason was all this page said.
            if let trouble = CameraTrouble(model.camera) {
                CameraTroubleCard(trouble: trouble, model: model, actions: actions)
            }
            HStack(alignment: .center, spacing: 26) {
                ProofRing(model: model)
                VStack(alignment: .leading, spacing: 12) {
                    Text(headline)
                        .textStyle(.title2, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TickDots(test: model.proofTest, running: model.proof == .running)
                }
            }
            .padding(.vertical, 6)
            HStack(spacing: 10) {
                if model.camera == .on && !model.faceFound && model.proof != .running {
                    Text("No face in view: the test can start once the camera sees you.")
                        .textStyle(.callout)
                        .foregroundStyle(Color.warningText)
                }
                Spacer(minLength: 12)
                buttons
            }
        }
    }

    private var result: ProofTest.Result? {
        if case .finished(let result) = model.proof { return result }
        return nil
    }

    private var headline: String {
        switch model.proof {
        case .ready: return "\(ProofTest.ticks) ticks. Blink once at each."
        case .running: return model.proofTest.answered.isEmpty ? "Get ready" : "Blink at each tick"
        case .finished(let result):
            return result.passed ? "\(result.found) of \(result.of) blinks counted" : "Only \(result.found) of \(result.of) blinks counted"
        }
    }

    private var explanation: String {
        switch model.proof {
        case .ready:
            return "The ticks come a second and a half apart. Blink quickly and lightly, the way you blink without thinking: "
                + "those are the ones that get missed. It takes fifteen seconds."
        case .running:
            return "The ring fills at each blink the model counts. The eye in the menu bar blinks with you too."
        case .finished(let result):
            var text: String
            if result.found == result.of {
                text = "Your model sees your blinks."
            } else if result.passed {
                text = "Good enough to count on. The lightest blinks are the hardest to see; one more recording in this light would help."
            } else if model.failedTests < 2 {
                text = "Too few to trust the count. A missed tick is the usual reason: test again, and blink at each tick as it sounds, "
                    + "lightly but all the way down."
            } else {
                text = "Too few again. One more recording, where you sit now, usually fixes it: "
                    + "the model then learns from eyes in this light."
            }
            if result.extra > 0 {
                text += " It also counted \(Format.count(result.extra, "blink")) between the ticks, which may well be yours."
            }
            return text
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.proof {
        case .ready:
            Button("Start the Test") { model.startTest() }
                .mainButton()
                .controlSize(.large)
                .disabled(!model.canStartTest)
        case .running:
            Button("Start Again") { model.testAgain() }
                .controlSize(.large)
        case .finished(let result):
            if result.passed {
                Button("Test Again") { model.testAgain() }
                    .controlSize(.large)
                Button("Finish") { model.finish() }
                    .mainButton()
                    .controlSize(.large)
            } else {
                if model.hasPrevious {
                    Button("Keep My Previous Model") { model.goBackToPrevious() }
                }
                Button("Use It Anyway") { model.useAnyway() }
                    .help("The app will count with this model and may miss blinks, so your rate can read lower than it is. You can test or record again later in Settings > Model.")
                // A first failure is often a missed tick: the test again comes first.
                // After a second one, two more minutes of recording are worth it.
                if model.failedTests < 2 {
                    Button("Record One More") { model.recordOneMore() }
                        .controlSize(.large)
                    Button("Test Again") { model.testAgain() }
                        .mainButton()
                        .controlSize(.large)
                } else {
                    Button("Test Again") { model.testAgain() }
                        .controlSize(.large)
                    Button("Record One More") { model.recordOneMore() }
                        .mainButton()
                        .controlSize(.large)
                }
            }
        }
    }
}

/// The count, in a ring that fills with each blink the model counted at a tick.
private struct ProofRing: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        let found = model.proofTest.answered.filter { $0 }.count
        let finished: ProofTest.Result? = { if case .finished(let result) = model.proof { return result } else { return nil } }()
        let colour: Color = finished.map { $0.passed ? .green : .orange } ?? .green
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 12)
            Circle()
                .trim(from: 0, to: Double(finished?.found ?? found) / Double(ProofTest.ticks))
                .stroke(colour, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: found)
            // A soft disc while the model reads your eyes as closed: it is watching.
            Circle()
                .fill(Color.green.opacity(model.eyesClosed && model.proof == .running ? 0.14 : 0))
                .padding(14)
            if let finished, finished.found == finished.of {
                Image(systemName: "checkmark")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: -2) {
                    Text("\(finished?.found ?? found)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(ProofTest.ticks)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 160, height: 160)
        .padding(6)                              // the ring's line is drawn half outside its circle
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(finished?.found ?? found) of \(ProofTest.ticks) blinks counted")
    }
}

/// One dot per tick: filled when a blink answered it, hollow when none did.
private struct TickDots: View {
    let test: ProofTest
    let running: Bool

    var body: some View {
        let answered = test.answered
        HStack(spacing: 7) {
            ForEach(0..<ProofTest.ticks, id: \.self) { index in
                ZStack {
                    if index < answered.count {
                        // The tick being answered right now is not yet a miss.
                        let pending = running && index == answered.count - 1 && !answered[index]
                        Circle().fill(answered[index] ? Color.green : (pending ? Color.accentColor.opacity(0.35) : Color.clear))
                        if !answered[index] && !pending { Circle().stroke(Color.orange, lineWidth: 2) }
                    } else {
                        Circle().fill(Color.primary.opacity(0.12))
                    }
                }
                .frame(width: 13, height: 13)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Done
