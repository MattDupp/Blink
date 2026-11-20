import SwiftUI
import BlinkCore
import BlinkUI

/// The live test window: the camera with the eye squares, the counters, and the model's
/// answer drawn as a curve over the last 10 seconds.
struct DiagnosticsView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var captures: CaptureController

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CameraPreview(model: model)
                Counters(model: model)
                    .frame(width: 300)
            }
            TraceView(model: model)
                .frame(height: 190)
            HStack(spacing: 12) {
                Toggle("Sound at each blink", isOn: $model.soundOn)
                Spacer()
                Button("Record cued blinks (30 s)") { model.startCapture(cued: true) }
                    .disabled(model.stage != .running || model.paused || captures.isCapturing)
                Button("Record freely (60 s)") { model.startCapture(cued: false) }
                    .disabled(model.stage != .running || model.paused || captures.isCapturing)
                Button("Reset counters") { model.resetCounters() }
            }
            CaptureBanner(captures: captures)
        }
        .padding(16)
        .frame(minWidth: 980, minHeight: 700)
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
                    .font(.system(size: 18, weight: .semibold))
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

// MARK: - Camera

private struct CameraPreview: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        // Green = read as open, orange = read as closed.
        CameraPreviewView(image: model.preview, frameSize: model.frameSize, eyeRects: model.eyeRects,
                          tint: model.eyesClosed ? .orange : .green, placeholder: placeholder)
    }

    private var placeholder: String {
        switch model.stage {
        case .denied:
            return "Camera access was refused.\nSystem Settings > Privacy & Security > Camera > allow Blink Monitor, then open it again."
        case .failed(let reason):
            return reason
        case .running where model.paused:
            return "Paused: the camera is off."
        default:
            return "Starting the camera..."
        }
    }
}

// MARK: - Counters

private struct Counters: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.ratePerMinute.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("blinks per minute")
                    .font(.headline)
                Text(model.ratePerMinute == nil ? "shown after 20 s of watching your eyes" : "over the last minute watched")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Row(label: "Blinks counted", value: "\(model.totalBlinks)")
            Row(label: "In the last 60 s", value: "\(model.blinksLastMinute)")
            Row(label: "Time watched", value: clock(model.observedSeconds))
            Row(label: "Last blink lasted",
                value: model.lastBlinkSeconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "--")
            Row(label: "Long closures (not blinks)", value: "\(model.longClosures)")

            Divider()

            Row(label: "Eyes now", value: eyesNow)
            Row(label: "Model: closed", value: model.probability.map { String(format: "%.0f%%", $0 * 100) } ?? "--")

            Divider()

            // The pipeline's own cost, averaged over the last two seconds.
            if let timings = model.timings {
                Row(label: "Per frame", value: String(format: "%.1f ms (worst %.1f)", timings.total, timings.worstTotal))
                Row(label: "Find eyes / crop / model",
                    value: String(format: "%.1f / %.1f / %.1f ms", timings.findEyes, timings.crop, timings.model))
                Row(label: "Frames a second", value: String(format: "%.0f, %.0f%% analysed",
                                                           timings.framesPerSecond, timings.analysedShare * 100))
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
        if !model.faceFound { return "no face" }
        if model.probability == nil { return "not readable" }
        return model.eyesClosed ? "closed" : "open"
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
            Text("Model's answer over the last \(Int(MonitorModel.traceSeconds)) seconds  (top = closed, bottom = open; green band = counted as a blink)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Canvas { context, size in
                let window = MonitorModel.traceSeconds
                let now = model.now
                func x(_ time: Double) -> CGFloat { CGFloat((time - (now - window)) / window) * size.width }
                func y(_ probability: Double) -> CGFloat { CGFloat(1 - probability) * (size.height - 12) + 6 }

                // The blinks that were counted.
                for blink in model.recentBlinks where blink.end > now - window {
                    let band = CGRect(x: x(blink.start), y: 0,
                                      width: max(x(blink.end) - x(blink.start), 3), height: size.height)
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
                for sample in model.trace where sample.time > now - window {
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
        }
    }
}
