import Foundation
import IOKit.ps
import BlinkCore

/// What the pipeline costs the Mac, stage by stage: processor time, graphics-processor
/// time and the processor's energy, with the frames handed over at the camera's pace.
///
///     BlinkReplay <folder> --cost=<stage>     one pass over the captures, one line of numbers
///       frames     read the frames and do nothing: what the replay itself costs
///       find       ... and find the eyes (Vision)
///       crop       ... and cut the eye pictures out (Core Image)
///       model      ... and ask the model, then count: the whole pipeline, as the app runs it
///       --weights=<eyenet.weights>   ask the network written in Swift (a model trained in
///                                    the app) instead of the Core ML model
///       --search-every=<n> --detect-every=<n>   another way of finding the eyes
///       --log=<file.csv> --label=<word>         also add the line to a file
///
/// HOW TO READ IT. The replay decodes a movie, which the app never does, so no line is the
/// app's cost by itself. A stage's cost is the difference between two lines: `model`
/// minus `frames` is the pipeline, `find` minus `frames` is Vision, and so on. Run each
/// several times: the spread between two runs of the same line is the smallest saving
/// these numbers can show. The power source is written on every line, because a Mac on
/// its battery does not clock its processor as it does on the charger.
enum Cost {

    enum Stage: String {
        case frames, find, crop, model
    }

    static func run(_ stage: Stage, captures: [RecordedCapture], classifier: EyeJudging, judge: String,
                    schedule: FrameSchedule, strategy: EyeLocator.Strategy) async throws {
        var seconds = 0.0, wall = 0.0
        var used = ProcessCost()
        var gpuKnown = true
        var costs: [(timings: StageTimings.Summary, frames: Double)] = []
        var score = BlinkScore()
        var counted = 0

        for capture in captures {
            let frames = try await WholeFrameReader(folder: capture.folder)
            let before = ProcessCost.now(), start = StageTimings.now()
            var lines: [TraceLine] = []
            switch stage {
            case .model:
                let reader = EyeReader(classifier: classifier, finder: EyeFinder(locator: EyeLocator(strategy: strategy), schedule: schedule))
                let outcome = try CaptureReplay.run(frames, reader: reader, atCameraPace: true)
                lines = outcome.lines
                if let timings = outcome.timings { costs.append((timings, Double(lines.count) * timings.analysedShare)) }
            case .frames, .find, .crop:
                let outcome = try paced(frames, stage: stage, schedule: schedule, strategy: strategy)
                seconds += outcome.seconds
                if let timings = outcome.timings { costs.append((timings, Double(outcome.frames) * timings.analysedShare)) }
            }
            wall += StageTimings.now() - start
            if let before, let after = ProcessCost.now() {
                let spent = after - before
                used.cpuSeconds += spent.cpuSeconds
                used.performanceCoreSeconds += spent.performanceCoreSeconds
                used.instructions += spent.instructions
                used.cpuJoules += spent.cpuJoules
                if let gpu = spent.gpuSeconds { used.gpuSeconds = (used.gpuSeconds ?? 0) + gpu } else { gpuKnown = false }
            }
            if stage == .model {
                seconds += RecordedCapture.seconds(of: lines)
                counted += RecordedCapture.counted(in: lines).count
                if let marks = capture.marks { score = score + RecordedCapture.score(lines, against: marks) }
            }
        }
        guard seconds > 0 else { return }
        if !gpuKnown { used.gpuSeconds = nil }

        let frames = costs.reduce(0) { $0 + $1.frames }
        func mean(_ value: (StageTimings.Summary) -> Double) -> Double {
            costs.reduce(0) { $0 + value($1.timings) * $1.frames } / max(frames, 1)
        }
        let power = onBattery ? "battery" : "charger"
        let way = stage == .frames ? "-" : "search \(schedule.searchEvery) \(describe(strategy))"
        var text = String(format: "cost %@ (%@, %@, on %@): %.0f s of video | work %.1f million instructions a second | "
                              + "processor %.2f%% of one core (%.0f%% of it on performance cores) | ",
                          stage.rawValue, stage == .model ? judge : "no model", way, power, seconds,
                          used.instructions / seconds / 1_000_000, used.cpuSeconds / seconds * 100,
                          used.cpuSeconds > 0 ? used.performanceCoreSeconds / used.cpuSeconds * 100 : 0)
        text += used.gpuSeconds.map { String(format: "graphics %.2f%% | ", $0 / seconds * 100) } ?? "graphics not known | "
        text += String(format: "processor energy %.0f mW", used.cpuJoules / seconds * 1000)
        if !costs.isEmpty {
            text += String(format: " | per frame: finding the eyes %.2f ms, cropping %.2f ms, model %.2f ms, whole frame %.2f ms",
                           mean(\.findEyes), mean(\.crop), mean(\.model), mean(\.total))
        }
        if stage == .model { text += " | \(counted) blinks counted; against the marks: \(score)" }
        print(text)

        if let file = LaunchArguments.value(of: "log") {
            let log = try CSVAppender(url: URL(fileURLWithPath: file), header: Self.header)
            log.append([ISO8601DateFormatter().string(from: Date()), power, LaunchArguments.value(of: "label") ?? "", stage.rawValue,
                        stage == .model ? judge : "", way,
                        String(format: "%.1f", seconds), String(format: "%.1f", wall),
                        String(format: "%.0f", used.instructions / 1_000_000),
                        String(format: "%.3f", used.cpuSeconds), String(format: "%.3f", used.performanceCoreSeconds), used.gpuSeconds.map { String(format: "%.3f", $0) } ?? "",
                        String(format: "%.2f", used.cpuJoules),
                        String(format: "%.3f", mean(\.findEyes)), String(format: "%.3f", mean(\.crop)),
                        String(format: "%.3f", mean(\.model)), String(format: "%.3f", mean(\.total)),
                        "\(counted)", "\(score.found)", "\(score.blinks)", "\(score.falseBlinks)"])
        }
    }

    /// What a running program costs, watched from outside for a while:
    ///
    ///     BlinkReplay --cost-of=<pid> [--seconds=60]
    ///
    /// for a copy of the app that is running (the demo, or the app at work on a camera).
    static func watch(pid: pid_t, seconds: Double) {
        guard let before = ProcessCost.now(pid: pid) else {
            print("No process \(pid) of yours to read.")
            exit(1)
        }
        let start = StageTimings.now()
        usleep(UInt32(seconds * 1_000_000))
        guard let after = ProcessCost.now(pid: pid) else {
            print("Process \(pid) ended while it was watched.")
            exit(1)
        }
        let wall = StageTimings.now() - start
        let used = after - before
        var text = String(format: "process %d over %.0f s, on %@: work %.1f million instructions a second | "
                              + "processor %.2f%% of one core (%.0f%% of it on performance cores) | ",
                          pid, wall, onBattery ? "battery" : "charger", used.instructions / wall / 1_000_000,
                          used.cpuSeconds / wall * 100, used.cpuSeconds > 0 ? used.performanceCoreSeconds / used.cpuSeconds * 100 : 0)
        text += used.gpuSeconds.map { String(format: "graphics %.2f%% | ", $0 / wall * 100) } ?? "graphics not known | "
        text += String(format: "processor energy %.0f mW", used.cpuJoules / wall * 1000)
        print(text)
    }

    static let header = "time,power,label,stage,model,way,video_s,wall_s,instructions_millions,cpu_s,p_core_s,gpu_s,cpu_joules,find_ms,crop_ms,model_ms,frame_ms,counted,found,marked,false"

    static func describe(_ strategy: EyeLocator.Strategy) -> String {
        switch strategy {
        case .wholeFrame: return "whole frame"
        case .faceBox(let detectEvery, let follow): return "face 1 in \(detectEvery)" + (follow ? "" : " still")
        }
    }

    static var onBattery: Bool {
        (IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?) == kIOPMBatteryPowerKey
    }

    /// The first stages alone, at the camera's pace, on a queue of the camera's priority
    /// (`CaptureReplay.run` does the same for the whole pipeline).
    private static func paced(_ frames: WholeFrameReader, stage: Stage, schedule: FrameSchedule,
                              strategy: EyeLocator.Strategy) throws -> (seconds: Double, frames: Int, timings: StageTimings.Summary?) {
        var result: Result<(Double, Int, StageTimings.Summary?), Error>?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "blink.replay.frames", qos: .utility).async {
            result = Result {
                let locator = EyeLocator(strategy: strategy)
                let finder = EyeFinder(locator: locator, schedule: schedule)
                var rhythm = schedule
                var timings = StageTimings()
                var started: (clock: Double, camera: Double)?
                var last = 0.0, count = 0
                while true {
                    let more: Bool = try autoreleasepool {
                        guard let frame = try frames.next() else { return false }
                        let start = started ?? (StageTimings.now(), frame.time)
                        started = start
                        let wait = start.clock + (frame.time - start.camera) - StageTimings.now()
                        if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
                        timings.frameDelivered(at: StageTimings.now())
                        last = frame.time
                        count += 1

                        var cost = FrameCost()
                        let began = StageTimings.now()
                        switch stage {
                        case .frames:
                            return true
                        case .find:
                            // The schedule's rhythm, with nothing cut out afterwards.
                            guard rhythm.next() == .search else { break }
                            let eyes = try FrameCost.measure(into: &cost.findEyes) { try locator.locate(in: frame.pixels) }
                            rhythm.searched(found: eyes != nil)
                        case .crop, .model:
                            _ = try finder.find(in: frame.pixels, cost: &cost)
                        }
                        cost.total = StageTimings.now() - began
                        timings.record(cost)
                        return true
                    }
                    if !more { break }
                }
                return (last - (started?.camera ?? last), count, stage == .frames ? nil : timings.takeSummary(at: StageTimings.now()))
            }
            done.signal()
        }
        done.wait()
        return try result!.get()
    }
}
