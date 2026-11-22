import SwiftUI
import BlinkCore
import BlinkUI

/// The Live View window: what the pipeline sees and decides, as it happens.
///
/// On the left, the camera with the eye squares and, under it, the model's answer drawn as
/// a curve over the last 10 seconds. On the right, the counters and the pipeline's own cost.
/// At the bottom, the tools that record captures for study and training.
struct LiveView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var captures: CaptureController

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 12) {
                    CameraPreviewView(image: model.preview, frameSize: model.live.frameSize,
                                      eyeRects: model.live.eyeRects,
                                      tint: model.live.eyesClosed ? .orange : .green,   // green = read as open
                                      placeholder: model.cameraNote)
                    TraceView(model: model)
                        .frame(height: 150)
                }
                Counters(model: model)
                    .frame(width: 290)
            }
            CaptureBanner(captures: captures)
            if let folder = Options.wholeFrameRoot {
                // Said for as long as the mode is on, not only while a capture runs.
                Text("Captures also keep the whole camera picture (your face), in \(folder.path), as asked when the app was started.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Toggle("Sound at each blink", isOn: $model.soundOn)
                Spacer()
                Button("Record Cued Blinks (30 s)") { model.startCapture(cued: true) }
                    .disabled(!model.canCapture)
                    .help("A tick every 1.5 s, 20 times: blink once at each. Every frame is saved.")
                Button("Record Freely (60 s)") { model.startCapture(cued: false) }
                    .disabled(!model.canCapture)
                    .help("Carry on normally for a minute. Every frame is saved.")
                Button("Reset Counters") { model.resetCounters() }
            }
        }
        .padding(18)
        .frame(minWidth: 940, minHeight: 600)
    }
}

// MARK: - Capture

/// While a capture runs: what to do, and how far along it is. Afterwards: where it went.
private struct CaptureBanner: View {
    @ObservedObject var captures: CaptureController

    var body: some View {
        if let instruction = captures.instruction {
            VStack(alignment: .leading, spacing: 6) {
                Text(instruction)
                    .font(.system(size: 17, weight: .semibold))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Color.red).frame(width: geometry.size.width * captures.progress)
                    }
                }
                .frame(height: 6)
            }
            .padding(12)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if let result = captures.result {
            Text(result)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Counters

private struct Counters: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        let counters = model.live.counters
        VStack(alignment: .leading, spacing: 12) {
            RateReadout(rate: counters.ratePerMinute)

            Group {
                SectionTitle("Since the counters were reset")
                Row(label: "Blinks counted", value: "\(counters.totalBlinks)")
                Row(label: "In the last 60 s", value: "\(counters.blinksLastMinute)")
                Row(label: "Time watched", value: clock(counters.observedSeconds))
                Row(label: "Last blink lasted",
                    value: counters.lastBlinkSeconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "--")
                Row(label: "Long closures (not blinks)", value: "\(counters.longClosures)")
            }

            Group {
                SectionTitle("This frame")
                    .padding(.top, 4)
                Row(label: "Eyes", value: eyesNow)
                Row(label: "Eyes read", value: eyesRead)
                Row(label: "Each eye: closed", value: eachEye)
                Row(label: "Both combined: closed",
                    value: model.live.probability.map { String(format: "%.0f%%", $0 * 100) } ?? "--")
            }

            // The pipeline's own cost, averaged over the last two seconds.
            if let timings = model.timings {
                Group {
                    SectionTitle("Cost per frame")
                        .padding(.top, 4)
                    Row(label: "Whole frame", value: String(format: "%.1f ms", timings.total))
                    Row(label: "Finding the eyes", value: String(format: "%.1f ms", timings.findEyes))
                    Row(label: "Cropping", value: String(format: "%.1f ms", timings.crop))
                    Row(label: "Model", value: String(format: "%.1f ms", timings.model))
                    Row(label: "Slowest frame", value: String(format: "%.1f ms", timings.worstTotal))
                    Row(label: "Frames a second", value: String(format: "%.0f (%.0f%% analysed)",
                                                                timings.framesPerSecond, timings.analysedShare * 100))
                }
            }

            if let problem = model.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var eyesNow: String {
        if !model.live.faceFound { return "no face" }
        if model.live.probability == nil { return "not readable" }
        return model.live.eyesClosed ? "closed" : "open"
    }

    /// How many eyes the model is asked about, and why not both. One square on the picture
    /// is not a fault: with the head turned, the far eye hides behind the nose.
    private var eyesRead: String {
        guard model.live.faceFound else { return "--" }
        switch model.live.eyeAnswers.count {
        case 2: return "2 of 2"
        case 1: return model.live.headTurned ? "1 of 2: head turned" : "1 of 2: one at the picture's edge"
        default: return "0 of 2: at the picture's edge"
        }
    }

    /// The left and the right of the PICTURE, as the squares are drawn.
    private var eachEye: String {
        func answer(_ side: EyeRegion.Side) -> String {
            model.live.eyeAnswers[side].map { String(format: "%.0f%%", $0 * 100) } ?? "--"
        }
        return "left \(answer(.imageLeft))   right \(answer(.imageRight))"
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct Row: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The model's answer over time

/// The curve is the model's "closed" probability, frame by frame: flat at the bottom while
/// the eyes are open, a spike up at each blink. A spike that was counted as a blink gets a
/// green band behind it; a spike WITHOUT a band was rejected by the detector's rules.
private struct TraceView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The model's answer over the last \(Int(Curve.seconds)) seconds: top = closed, bottom = open. Green band = counted as a blink.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Canvas { context, size in
                let window = Curve.seconds
                let now = model.curve.now
                func x(_ time: Double) -> CGFloat { CGFloat((time - (now - window)) / window) * size.width }
                func y(_ probability: Double) -> CGFloat { CGFloat(1 - probability) * (size.height - 12) + 6 }

                // The blinks that were counted.
                for blink in model.curve.blinks where blink.end > now - window {
                    let band = CGRect(x: x(blink.start) - 2, y: 0,
                                      width: max(x(blink.end) - x(blink.start), 3) + 2, height: size.height)
                    context.fill(Path(band), with: .color(.green.opacity(0.3)))
                }

                // The detector's two thresholds: closed above 60%, open again below 40%.
                let thresholds = BlinkDetector.Settings()
                for level in [thresholds.closedAbove, thresholds.openBelow] {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y(level)))
                    line.addLine(to: CGPoint(x: size.width, y: y(level)))
                    context.stroke(line, with: .color(.secondary.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }

                // The curve. A hole in the data (no face) breaks the line instead of
                // drawing a straight stroke across it.
                var curve = Path()
                var previous: Double?
                for sample in model.curve.samples where sample.time > now - window {
                    let point = CGPoint(x: x(sample.time), y: y(sample.probability))
                    if let previous, sample.time - previous < 0.2 {
                        curve.addLine(to: point)
                    } else {
                        curve.move(to: point)
                    }
                    previous = sample.time
                }
                context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("The model's answer over the last ten seconds")
        }
    }
}
