import Foundation
import BlinkCore

/// Replays the captures that kept their whole frames, and counts.
///
///     BlinkReplay <folder> [<folder> ...]    a capture, or a folder of captures (data/replay)
///       --model=<EyeNet.mlmodelc>            the model to ask (default: models/EyeNet.mlmodelc)
///       --pace                               hand the frames over at the camera's pace, and
///                                            report what each stage costs
///       --search-every=<n>[,<n>]             also try searching for the eyes on one frame in n
///
/// For each capture it prints how many of the blinks a person marked (blinks.csv) are
/// counted: as the app counted them while recording, then replayed from the stored frames
/// through each way of finding the eyes. `make replay` runs it on data/replay.
@main
enum Entry {

    /// One way of finding the eyes, to be judged.
    struct Variant {
        /// Short, for the name of the trace file.
        let name: String
        let title: String
        /// Search on every frame, whatever the schedule says.
        var everyFrame = false
        var schedule = FrameSchedule()
    }

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let roots = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !roots.isEmpty else {
            print("usage: BlinkReplay <capture or folder of captures> ... [--model=<EyeNet.mlmodelc>] [--pace] [--search-every=<n>]")
            exit(2)
        }
        let paced = LaunchArguments.has("pace")
        let model = LaunchArguments.folder("model") ?? URL(fileURLWithPath: "models/EyeNet.mlmodelc", isDirectory: true)
        let classifier = try EyeClassifier(compiledModel: model)

        var captures: [RecordedCapture] = []
        for folder in roots.flatMap(RecordedCapture.folders(in:)) {
            guard WholeFrameReader.hasFrames(folder) else {
                print("\(folder.lastPathComponent): keeps no whole frames, left out")
                continue
            }
            captures.append(try RecordedCapture(folder: folder))
        }
        guard !captures.isEmpty else {
            print("No capture with whole frames in \(roots.map(\.path).joined(separator: ", ")).")
            print("Record some: make monitor WHOLE_FRAMES=1, then the capture buttons of the Live View window.")
            exit(1)
        }

        let seconds = captures.reduce(0) { $0 + RecordedCapture.seconds(of: $1.trace) }
        let marked = captures.compactMap(\.marks).joined().filter { $0.kind == .blink }.count
        print(String(format: "\n%d captures with whole frames, %.0f s of video, %d blinks marked by eye.",
                     captures.count, seconds, marked))
        for capture in captures where capture.marks == nil {
            print("  \(capture.name) is not marked yet (or not all of it): its blinks are counted, not judged.")
            print("  To mark it:  cd training && uv run python annotate.py --replay   then fill the 'kind' column of its blinks.csv")
        }

        // The reference: what the app itself answered, from the camera, while recording.
        print("\nAs the app counted while it recorded (the eyes searched on every frame):")
        report(captures.map { ($0, $0.trace) })

        var variants = [
            Variant(name: "every-frame", title: "Replayed from the stored frames, the eyes searched on every frame", everyFrame: true),
            Variant(name: "app", title: "Replayed as the app runs: \(describe(FrameSchedule()))"),
        ]
        for text in (LaunchArguments.value(of: "search-every") ?? "").split(separator: ",") {
            guard let every = Int(text), every >= 1, every != FrameSchedule().searchEvery else { continue }
            var schedule = FrameSchedule()
            schedule.searchEvery = every
            variants.append(Variant(name: "search-every-\(every)", title: "Replayed: \(describe(schedule))", schedule: schedule))
        }

        for variant in variants {
            print("\n\(variant.title):")
            var replays: [(RecordedCapture, [TraceLine])] = []
            var costs: [StageTimings.Summary] = []
            for capture in captures {
                let frames = try await WholeFrameReader(folder: capture.folder)
                let reader = EyeReader(classifier: classifier, finder: EyeFinder(schedule: variant.schedule))
                let file = capture.folder.appendingPathComponent("replays/\(variant.name).csv")
                try? FileManager.default.removeItem(at: file)
                let outcome = try CaptureReplay.run(frames, reader: reader, everyFrame: variant.everyFrame, atCameraPace: paced,
                                                    trace: try CSVAppender(url: file, header: CaptureWriter.header))
                replays.append((capture, outcome.lines))
                if let timings = outcome.timings { costs.append(timings) }
            }
            report(replays)
            if variant.everyFrame {
                // The same work on the same frames as the recording: what differs is what
                // keeping the frames in a movie did to them.
                print("  (the app's own work on the same frames: what differs from the lines above is what storing the frames changed)")
            }
            for (capture, lines) in replays {
                let gap = CaptureReplay.difference(capture.trace, lines)
                print(String(format: "  %@  answers differ from the recorded ones by %.1f%% on average, %.0f%% at most; "
                             + "%d of %d frames on the other side of 50%%, %d read by one only",
                             capture.name.padding(toLength: 26, withPad: " ", startingAt: 0),
                             gap.meanGap * 100, gap.largestGap * 100, gap.otherSide, gap.compared, gap.readByOneOnly))
            }
            if paced, !costs.isEmpty {
                let n = Double(costs.count)
                func mean(_ value: (StageTimings.Summary) -> Double) -> Double { costs.reduce(0) { $0 + value($1) } / n }
                print(String(format: "  cost per analysed frame: finding the eyes %.2f ms, cropping %.2f ms, model %.2f ms, whole frame %.2f ms "
                             + "(%.0f%% of the frames analysed)",
                             mean(\.findEyes), mean(\.crop), mean(\.model), mean(\.total), mean(\.analysedShare) * 100))
            }
        }
        if !paced {
            print("\nFor what each way costs, replay at the camera's pace:  make replay PACE=1")
        }
    }

    static func describe(_ schedule: FrameSchedule) -> String {
        switch schedule.searchEvery {
        case 1: return "the eyes searched on every frame"
        case 2: return "the eyes searched on every other frame"
        default: return "the eyes searched on one frame in \(schedule.searchEvery)"
        }
    }

    /// One line per capture, and their sum.
    static func report(_ runs: [(capture: RecordedCapture, lines: [TraceLine])]) {
        var total = BlinkScore()
        var judged = 0
        for (capture, lines) in runs {
            let name = capture.name.padding(toLength: 26, withPad: " ", startingAt: 0)
            if let marks = capture.marks {
                let score = RecordedCapture.score(lines, against: marks)
                total = total + score
                judged += 1
                print("  \(name) \(score)")
            } else {
                print("  \(name) \(RecordedCapture.counted(in: lines).count) blinks counted (not marked yet)")
            }
        }
        if judged > 1 { print("  \("all".padding(toLength: 26, withPad: " ", startingAt: 0)) \(total)") }
    }
}
