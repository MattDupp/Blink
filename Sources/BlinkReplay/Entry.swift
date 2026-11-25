import Foundation
import BlinkCore

/// Replays the captures that kept their whole frames, and counts.
///
///     BlinkReplay <folder> [<folder> ...]    a capture, or a folder of captures (data/replay)
///       --model=<EyeNet.mlmodelc>            the model to ask (default: models/EyeNet.mlmodelc)
///       --pace                               hand the frames over at the camera's pace, and
///                                            report what each stage costs
///       --search-every=<n>[,<n>]             also try searching for the eyes on one frame in n
///       --detect-every=<n>[,<n>]             also try finding the FACE on one search in n only, and
///                                            placing the landmarks in its box in between
///                                            (0: find the face on every search)
///       --still-box                          ... without moving that box with the eyes
///     With both, every rhythm is tried with every way of finding the face.
///       --weights=<eyenet.weights>           ask the network written in Swift (a model trained
///                                            in the app) instead of the Core ML model
///       --core-image-crops                   cut the eye pictures with Core Image, as the app
///                                            did until 2026-11-23, instead of on the processor
///       --traces=<folder>                    write each run's answers there, frame by frame,
///                                            instead of in the capture's own folder
///       --squares                            beside each run's answers, where its eye squares
///                                            were on each frame (<run>-squares.csv)
///
///     BlinkReplay <folder> --cost=<stage>    what a stage costs the Mac: processor, graphics
///                                            processor, energy (Cost.swift)
///     BlinkReplay --cost-of=<pid>            what a running copy of the app costs, watched
///       [--seconds=60]                       from outside
///     BlinkReplay <folder> --crops           how far the eye pictures cut on the processor
///                                            are from Core Image's (Crops.swift)
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
        var strategy = EyeLocator.Strategy.wholeFrame
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
        // A running program's cost, watched from outside: no capture is read.
        if let pid = LaunchArguments.value(of: "cost-of").flatMap({ Int32($0) }) {
            Cost.watch(pid: pid, seconds: LaunchArguments.value(of: "seconds").flatMap { Double($0) } ?? 60)
            return
        }
        let roots = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !roots.isEmpty else {
            print("usage: BlinkReplay <capture or folder of captures> ... [--model=<EyeNet.mlmodelc>] [--pace] [--search-every=<n>]")
            exit(2)
        }
        let paced = LaunchArguments.has("pace")
        let model = LaunchArguments.folder("model") ?? URL(fileURLWithPath: "models/EyeNet.mlmodelc", isDirectory: true)
        // A model trained in the app is run by the network written in Swift: named
        // with --weights, it is asked instead of the Core ML model.
        let classifier: EyeJudging
        let judge: String
        if let weights = LaunchArguments.value(of: "weights") {
            classifier = EyeNetwork(weights: try EyeNetWeights(contentsOf: URL(fileURLWithPath: weights)))
            judge = "the network written in Swift"
        } else {
            classifier = try EyeClassifier(compiledModel: model)
            judge = "Core ML"
        }

        var captures: [RecordedCapture] = []
        for folder in roots.flatMap(RecordedCapture.folders(in:)) {
            guard WholeFrameReader.hasFrames(folder) else {
                print("\(folder.lastPathComponent): keeps no whole frames, left out")
                continue
            }
            captures.append(try RecordedCapture(folder: folder))
        }
        // What the app answered while recording, for the frames the movie holds. (The
        // last frame or two of a capture are in its trace and not in its movie: the
        // movie is closed while the camera still delivers. A blink that reopens on those
        // frames cannot be replayed, so it is not held against the replays either.)
        var live: [String: [TraceLine]] = [:]
        for capture in captures {
            let stored = Set(try await WholeFrameReader(folder: capture.folder).numbers)
            live[capture.name] = capture.trace.filter { stored.contains($0.frame) }
        }
        guard !captures.isEmpty else {
            print("No capture with whole frames in \(roots.map(\.path).joined(separator: ", ")).")
            print("Record some: make monitor WHOLE_FRAMES=1, then the capture buttons of the Live View window.")
            exit(1)
        }

        // The eye pictures cut on the processor, against Core Image's: see Crops.swift.
        if LaunchArguments.has("crops") {
            try await Crops.run(captures: captures, classifier: classifier, judge: judge)
            return
        }
        // What a stage costs the Mac, instead of what it counts: see Cost.swift.
        if let asked = LaunchArguments.value(of: "cost") {
            guard let stage = Cost.Stage(rawValue: asked) else {
                print("--cost= takes frames, find, crop or model")
                exit(2)
            }
            func number(_ name: String) -> Int? { LaunchArguments.value(of: name).flatMap { Int($0) } }
            var schedule = FrameSchedule()
            if let asked = LaunchArguments.value(of: "effort") {
                guard let effort = Effort(rawValue: asked) else {
                    print("--effort= takes \(Effort.allCases.map(\.rawValue).joined(separator: ", "))")
                    exit(2)
                }
                schedule = effort.schedule
            }
            if let every = number("search-every"), every >= 1 { schedule.searchEvery = every }
            var strategy = EyeLocator.usual
            if let every = number("detect-every") {
                strategy = every == 0 ? .wholeFrame : .faceBox(detectEvery: every, follow: !LaunchArguments.has("still-box"))
            }
            try await Cost.run(stage, captures: captures, classifier: classifier, judge: judge, schedule: schedule, strategy: strategy,
                               flatOut: LaunchArguments.has("flat-out"))
            return
        }

        let seconds = captures.reduce(0) { $0 + RecordedCapture.seconds(of: $1.trace) }
        let marked = captures.compactMap(\.marks).joined().filter { $0.kind == .blink }.count
        print(String(format: "\n%d capture%@ with whole frames, %.0f s of video, %d blinks marked by eye.",
                     captures.count, captures.count == 1 ? "" : "s", seconds, marked))
        for capture in captures where capture.marks == nil {
            print("  \(capture.name) is not marked yet (or not all of it): its blinks are counted, not judged.")
            print("  To mark it:  cd training && uv run python annotate.py --replay   then fill the 'kind' column of its blinks.csv")
        }

        // The reference: what the app itself answered, from the camera, while recording.
        print("\nAs the app counted while it recorded (the eyes searched on every frame):")
        report(captures.map { ($0, live[$0.name] ?? []) })

        var variants = [
            Variant(name: "every-frame", title: "Replayed from the stored frames, the eyes searched on every frame", everyFrame: true),
            Variant(name: "app", title: "Replayed as the app runs: \(describe(FrameSchedule(), EyeLocator.usual))",
                    strategy: EyeLocator.usual),
        ]
        // The other levels of effort a person can choose in Settings (`Effort`).
        for effort in Effort.allCases where effort != .standard {
            variants.append(Variant(name: effort.rawValue,
                                    title: "Replayed as the app runs with its effort on \(effort.rawValue): \(describe(effort.schedule, EyeLocator.usual))",
                                    schedule: effort.schedule, strategy: EyeLocator.usual))
        }
        // Other ways, asked for on the command line: every rhythm with every strategy.
        func numbers(_ name: String) -> [Int]? {
            LaunchArguments.value(of: name).map { $0.split(separator: ",").compactMap { Int($0) }.filter { $0 >= 0 } }
        }
        let rhythms = numbers("search-every")?.filter { $0 >= 1 }, detections = numbers("detect-every")
        let follow = !LaunchArguments.has("still-box")
        if rhythms != nil || detections != nil {
            let strategies: [EyeLocator.Strategy] = detections?.map {
                $0 == 0 ? .wholeFrame : .faceBox(detectEvery: $0, follow: follow)
            } ?? [EyeLocator.usual]
            for every in rhythms ?? [FrameSchedule().searchEvery] {
                for strategy in strategies {
                    var schedule = FrameSchedule()
                    schedule.searchEvery = every
                    guard every != FrameSchedule().searchEvery || strategy != EyeLocator.usual else { continue }   // "app"
                    var name = "search-\(every)"
                    if case .faceBox(let detectEvery, let follow) = strategy { name += "-box-\(detectEvery)" + (follow ? "" : "-still") }
                    variants.append(Variant(name: name, title: "Replayed: \(describe(schedule, strategy))",
                                            schedule: schedule, strategy: strategy))
                }
            }
        }

        var reference: [String: [TraceLine]] = [:]
        for variant in variants {
            print("\n\(variant.title):")
            var replays: [(capture: RecordedCapture, lines: [TraceLine])] = []
            /// Each capture's stage timings, and how many frames they are an average of.
            var costs: [(timings: StageTimings.Summary, frames: Double)] = []
            var searches = EyeLocator.Counts()
            for capture in captures {
                let frames = try await WholeFrameReader(folder: capture.folder)
                let locator = EyeLocator(strategy: variant.strategy)
                let reader = EyeReader(classifier: classifier,
                                       finder: EyeFinder(locator: locator, schedule: variant.schedule, cropper: cropper()))
                // Each run's answers, frame by frame: beside the capture, or in the folder
                // named with --traces (a capture that must not be written to).
                let file = LaunchArguments.folder("traces")?.appendingPathComponent("\(capture.name)-\(variant.name).csv")
                    ?? capture.folder.appendingPathComponent("replays/\(variant.name).csv")
                try? FileManager.default.removeItem(at: file)
                var squares: CSVAppender?
                if LaunchArguments.has("squares") {
                    let squaresFile = file.deletingPathExtension().appendingPathExtension("squares.csv")
                    try? FileManager.default.removeItem(at: squaresFile)
                    squares = try CSVAppender(url: squaresFile, header: CaptureReplay.squaresHeader)
                }
                let outcome = try CaptureReplay.run(frames, reader: reader, everyFrame: variant.everyFrame, atCameraPace: paced,
                                                    trace: try CSVAppender(url: file, header: CaptureWriter.header),
                                                    squares: squares)
                replays.append((capture, outcome.lines))
                if let timings = outcome.timings {
                    costs.append((timings, Double(outcome.lines.count) * timings.analysedShare))
                }
                searches.wholeFrame += locator.counts.wholeFrame
                searches.inBox += locator.counts.inBox
                searches.doubted += locator.counts.doubted
                searches.wholeFrameSeconds += locator.counts.wholeFrameSeconds
                searches.inBoxSeconds += locator.counts.inBoxSeconds
            }
            report(replays)
            if variant.everyFrame {
                // The same work on the same frames as the recording: what differs is what
                // keeping the frames in a movie did to them.
                print("  The app's own work on the same frames. What differs from the recording is what storing the frames changed:")
                for (capture, lines) in replays {
                    let gap = CaptureReplay.difference(live[capture.name] ?? [], lines)
                    print(String(format: "  %@ answers %.1f%% apart on average, %.0f%% at most; %d of %d frames on the other side of 50%%; %@",
                                 pad(capture.name), gap.meanGap * 100, gap.largestGap * 100, gap.otherSide, gap.compared,
                                 describe(CaptureReplay.sameBlinks(live[capture.name] ?? [], lines), first: "the recording", second: "the replay")))
                }
                reference = Dictionary(uniqueKeysWithValues: replays.map { ($0.capture.name, $0.lines) })
            } else {
                // Against the replay that searches every frame: same frames, same model,
                // only the eye finding differs.
                print("  Against the replay that searches on every frame:")
                for (capture, lines) in replays {
                    let gap = CaptureReplay.difference(reference[capture.name] ?? [], lines)
                    print(String(format: "  %@ answers %.1f%% apart on average; %d of %d frames on the other side of 50%%, %d read by one only; %@",
                                 pad(capture.name), gap.meanGap * 100, gap.otherSide, gap.compared, gap.readByOneOnly,
                                 describe(CaptureReplay.sameBlinks(reference[capture.name] ?? [], lines), first: "every frame", second: "this")))
                }
            }
            // What one search of each kind costs: the two are timed in the same run, so
            // the comparison does not depend on how busy the Mac was during it.
            let inBox = searches.inBox + searches.doubted
            var text = String(format: "  searches: %d of the whole frame (%.1f ms each)", searches.wholeFrame,
                              searches.wholeFrameSeconds / Double(max(searches.wholeFrame, 1)) * 1000)
            if inBox > 0 {
                text += String(format: ", %d in the face's box (%.1f ms each), of which %d were doubted and done again in the whole frame",
                               inBox, searches.inBoxSeconds / Double(inBox) * 1000, searches.doubted)
            }
            print(text)
            if !costs.isEmpty {
                // Averaged over the frames, not over the captures: a long capture weighs more.
                let frames = costs.reduce(0) { $0 + $1.frames }
                func mean(_ value: (StageTimings.Summary) -> Double) -> Double {
                    costs.reduce(0) { $0 + value($1.timings) * $1.frames } / max(frames, 1)
                }
                print(String(format: "  cost per frame %@: finding the eyes %.2f ms, cropping %.2f ms, model %.2f ms, whole frame %.2f ms",
                             paced ? "at the camera's pace" : "as fast as the frames can be read (not what the app pays)",
                             mean(\.findEyes), mean(\.crop), mean(\.model), mean(\.total)))
            }
        }
        if !paced {
            print("\nFor what each way costs in the app, replay at the camera's pace:  make replay PACE=1")
        }
    }

    /// How the eye pictures are cut in this run: on the processor, as the apps do, unless
    /// Core Image is asked for.
    static func cropper() -> EyeCropper {
        EyeCropper(way: LaunchArguments.has("core-image-crops") ? .coreImage : .direct)
    }

    static func describe(_ schedule: FrameSchedule, _ strategy: EyeLocator.Strategy) -> String {
        let rhythm: String
        switch schedule.searchEvery {
        case 1: rhythm = "the eyes searched on every frame"
        case 2: rhythm = "the eyes searched on every other frame"
        default: rhythm = "the eyes searched on one frame in \(schedule.searchEvery)"
        }
        let forgetting = schedule.strayBeyond.map {
            String(format: "; what was read in squares the eyes had left by more than %.2f of their distance is forgotten", $0)
        } ?? ""
        switch strategy {
        case .wholeFrame:
            return rhythm + forgetting
        case .faceBox(let detectEvery, let follow):
            return rhythm + ", the face found on one search in \(detectEvery) and its box "
                + (follow ? "moved with the eyes" : "left where it was") + " in between" + forgetting
        }
    }

    static func pad(_ name: String) -> String {
        name.padding(toLength: 26, withPad: " ", startingAt: 0)
    }

    static func describe(_ blinks: CaptureReplay.SameBlinks, first: String, second: String) -> String {
        if blinks.same { return "the same \(blinks.both) blinks counted" }
        var text = "\(blinks.both) blinks counted by both"
        if !blinks.onlyFirst.isEmpty { text += ", only by \(first) at \(blinks.onlyFirst)" }
        if !blinks.onlySecond.isEmpty { text += ", only by \(second) at \(blinks.onlySecond)" }
        return text
    }

    /// One line per capture, and their sum.
    static func report(_ runs: [(capture: RecordedCapture, lines: [TraceLine])]) {
        var total = BlinkScore()
        var judged = 0
        for (capture, lines) in runs {
            let name = pad(capture.name)
            if let marks = capture.marks {
                let score = RecordedCapture.score(lines, against: marks)
                total = total + score
                judged += 1
                print("  \(name) \(score)")
            } else {
                print("  \(name) \(RecordedCapture.counted(in: lines).count) blinks counted (not marked yet)")
            }
        }
        if judged > 1 { print("  \(pad("all")) \(total)") }
    }
}
