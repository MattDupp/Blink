import Foundation
import CoreGraphics
import ImageIO
import BlinkCore

/// Checks what can be checked without the camera:
///   - the blink logic, on streams of answers written by hand, where the right count is known;
///   - the model inside Swift, against the answers Python computed for the same pictures.
enum SelfTest {

    private struct Reference: Decodable {
        let file: String
        let label: String
        let closed: Double
    }

    static func run() -> Bool {
        var allPassed = true
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print((passed ? "PASS  " : "FAIL  ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
            if !passed { allPassed = false }
        }

        // --- 1. The blink detector, at 30 frames a second ------------------------------
        let open = 0.02, closed = 0.98
        func events(_ stream: [Double?]) -> [BlinkDetector.Event] {
            var detector = BlinkDetector()
            var found: [BlinkDetector.Event] = []
            for (frame, probability) in stream.enumerated() {
                if let event = detector.update(time: Double(frame) / 30, closed: probability) { found.append(event) }
            }
            return found
        }
        func blinks(_ stream: [Double?]) -> Int {
            events(stream).filter { if case .blink = $0 { return true } else { return false } }.count
        }
        func frames(_ value: Double?, _ count: Int) -> [Double?] { Array(repeating: value, count: count) }

        let normal = events(frames(open, 15) + frames(closed, 4) + frames(open, 5))
        if case .blink(let blink)? = normal.first, normal.count == 1 {
            check("blink: open, 4 frames closed, open = one blink of 133 ms", abs(blink.duration - 4.0 / 30) < 0.001,
                  String(format: "%.0f ms", blink.duration * 1000))
        } else {
            check("blink: open, 4 frames closed, open = one blink", false, "\(normal)")
        }
        check("blink: two in a row are counted twice",
              blinks(frames(open, 10) + frames(closed, 3) + frames(open, 10) + frames(closed, 3) + frames(open, 5)) == 2)
        check("noise: one lone closed frame is not a blink",
              events(frames(open, 10) + frames(closed, 1) + frames(open, 10)).isEmpty)
        check("noise: an answer hovering around 50% is not a blink",
              events(frames(open, 5) + (0..<30).map { $0 % 2 == 0 ? 0.45 : 0.55 } + frames(open, 5)).isEmpty)
        check("hysteresis: a closure that dips to 50% in the middle is still one blink",
              blinks(frames(open, 10) + [closed, 0.5, 0.5, closed] + frames(open, 5)) == 1)

        let long = events(frames(open, 10) + frames(closed, 45) + frames(open, 5))
        check("long closure: 1.5 s closed is reported, not counted as a blink",
              long.count == 1 && { if case .longClosure(let seconds) = long[0] { return abs(seconds - 1.5) < 0.001 } else { return false } }())
        check("gap: face lost while the eyes were closed = nothing counted",
              events(frames(open, 10) + frames(closed, 2) + frames(nil, 30) + frames(open, 10)).isEmpty)
        check("start: eyes already closed when first seen = nothing counted",
              events(frames(closed, 5) + frames(open, 10)).isEmpty)

        // --- 2. The statistics -----------------------------------------------------------
        var stats = BlinkStats()
        for frame in 0...900 {                       // 30 s watched
            stats.frame(time: Double(frame) / 30, eyesRead: true)
        }
        for second in [3.0, 9.0, 15.0, 21.0, 27.0] {
            stats.record(.blink(Blink(start: second, end: second + 0.15)))
        }
        stats.record(.longClosure(seconds: 2))
        let rate = stats.ratePerMinute(inLast: 60, now: 30)
        check("rate: 5 blinks in 30 s watched = 10 per minute", rate.map { abs($0 - 10) < 0.01 } ?? false, "\(rate ?? -1)")
        check("counters: 5 blinks, 1 long closure, 30 s watched",
              stats.totalBlinks == 5 && stats.longClosures == 1 && abs(stats.observedSeconds - 30) < 0.001)

        var brief = BlinkStats()
        for frame in 0...300 { brief.frame(time: Double(frame) / 30, eyesRead: true) }   // 10 s
        check("rate: not given before 20 s were watched", brief.ratePerMinute(inLast: 60, now: 10) == nil)

        var away = BlinkStats()
        for frame in 0...900 { away.frame(time: Double(frame) / 30, eyesRead: frame < 300) }
        check("time watched: frames without readable eyes do not count",
              abs(away.observedSeconds - 299.0 / 30) < 0.001, String(format: "%.2f s", away.observedSeconds))

        // --- 2a. The history: frames sorted into minutes of the clock --------------------
        let ten = Date(timeIntervalSince1970: 1_800_000_000)     // a round minute
        var aggregator = MinuteAggregator()
        var finished: [MinuteRecord] = []
        for frame in 0..<(150 * 30) {                            // 150 s of frames at 30 a second
            let second = Double(frame) / 30
            // One blink every 6 s during the first minute, none afterwards.
            let blink = second < 60 && frame % 180 == 90 ? 1 : 0
            if let done = aggregator.add(at: ten.addingTimeInterval(second), observedSeconds: 1.0 / 30, blinks: blink) {
                finished.append(done)
            }
        }
        check("history: 150 s of frames = two finished minutes and one being filled",
              finished.count == 2 && finished[0].start == ten && finished[1].start == ten.addingTimeInterval(60)
              && aggregator.current?.start == ten.addingTimeInterval(120))
        check("history: the first minute holds 60 s watched and its 10 blinks",
              finished.count == 2 && abs(finished[0].observedSeconds - 60) < 0.01 && finished[0].blinks == 10
              && finished[1].blinks == 0, "\(finished.map { "\($0.observedSeconds) s, \($0.blinks)" })")
        check("history: a minute watched for under 20 s has no rate",
              MinuteRecord(start: ten, observedSeconds: 12, blinks: 3).ratePerMinute == nil
              && MinuteRecord(start: ten, observedSeconds: 30, blinks: 5).ratePerMinute == 10)

        let historyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-history-test-\(UUID().uuidString)/history.csv")
        defer { try? FileManager.default.removeItem(at: historyFile.deletingLastPathComponent()) }
        let store = HistoryStore(file: historyFile)
        finished.forEach { store.append($0) }
        let reloaded = store.load(since: ten)
        check("history: minutes written to disk read back the same",
              reloaded.count == 2 && reloaded[0].start == ten && reloaded[0].blinks == 10
              && abs(reloaded[0].observedSeconds - 60) < 0.06 && store.load(since: ten.addingTimeInterval(60)).count == 1)

        let summary = DaySummary(records: finished, threshold: 10)
        check("day: 120 s watched, 10 blinks, 5 a minute; one of two minutes under 10",
              abs(summary.observedSeconds - 120) < 0.01 && summary.blinks == 10
              && summary.ratePerMinute.map { abs($0 - 5) < 0.01 } == true
              && summary.ratedMinutes == 2 && summary.lowMinutes == 1)

        // --- 2a'. The reminders ----------------------------------------------------------
        func minute(_ index: Int, watched: Double, blinks: Int) -> MinuteRecord {
            MinuteRecord(start: ten.addingTimeInterval(Double(index) * 60), observedSeconds: watched, blinks: blinks)
        }
        let after3 = ten.addingTimeInterval(180)
        var policy = ReminderPolicy()
        let quiet = [minute(0, watched: 60, blinks: 4), minute(1, watched: 60, blinks: 5), minute(2, watched: 60, blinks: 3)]
        let quietRate = policy.recentRate(records: quiet, now: after3)
        check("reminder: 12 blinks in 3 minutes watched = 4 a minute", quietRate.map { abs($0 - 4) < 0.01 } == true, "\(quietRate ?? -1)")
        check("reminder: too little watched (you were away) = no rate, no reminder",
              policy.recentRate(records: [minute(2, watched: 40, blinks: 0)], now: after3) == nil
              && !policy.reminderDue(rate: nil, threshold: 10, now: after3))
        check("reminder: minutes older than the last 3 are not counted",
              policy.recentRate(records: [minute(-9, watched: 60, blinks: 0), minute(-8, watched: 60, blinks: 0)], now: after3) == nil)
        check("reminder: a rate over the threshold never reminds", !policy.reminderDue(rate: 14, threshold: 10, now: after3))
        check("reminder: a low rate reminds once, then waits 5 minutes",
              policy.reminderDue(rate: quietRate, threshold: 10, now: after3)
              && !policy.reminderDue(rate: quietRate, threshold: 10, now: after3.addingTimeInterval(240))
              && policy.reminderDue(rate: quietRate, threshold: 10, now: after3.addingTimeInterval(301)))

        // --- 2b. A capture on disk: every frame's pictures, one trace line per frame ----
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-capture-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let picture = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            let writer = try CaptureWriter(root: root, name: "test")
            writer.write(frame: 7, time: 0.2333,
                         eyes: [CapturedEye(side: .imageLeft, picture: picture, closed: 0.9, openness: 0.11),
                                CapturedEye(side: .imageRight, picture: picture, closed: 0.7, openness: 0.12)],
                         mean: 0.8, state: .closed(since: 0.2, frames: 1), event: nil, tick: true)
            writer.write(frame: 8, time: 0.2667, eyes: [], mean: nil, state: .unknown, event: nil, tick: false)

            let lines = ((try? String(contentsOf: root.appendingPathComponent("test/trace.csv"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            check("capture: both eyes' pictures of the frame are saved",
                  FileManager.default.fileExists(atPath: root.appendingPathComponent("test/frames/f000007_L.png").path)
                  && FileManager.default.fileExists(atPath: root.appendingPathComponent("test/frames/f000007_R.png").path))
            check("capture: one trace line per frame, with the answers, the state and the tick",
                  lines.count == 3 && lines[0] == CaptureWriter.header
                  && lines[1] == "7,0.2333,0.9000,0.7000,0.8000,0.1100,0.1200,closed,,1"
                  && lines[2] == "8,0.2667,,,,,,unknown,,",
                  lines.dropFirst().joined(separator: " | "))
        } catch {
            check("capture: written", false, "\(error)")
        }

        // --- 3. The model, in Swift, against Python's answers ---------------------------
        let classifier: EyeClassifier
        do {
            classifier = try EyeClassifier(compiledModel: Options.modelURL)
            check("model: loads from \(Options.modelURL.lastPathComponent)", true)
        } catch {
            check("model: loads from \(Options.modelURL.path)", false, "\(error)")
            print("RESULT: FAILED")
            return false
        }

        if let referenceURL = Options.referenceURL {
            do {
                let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: referenceURL))
                let project = referenceURL.deletingLastPathComponent().deletingLastPathComponent()
                var compared = 0, worst = 0.0, disagreements = 0
                for reference in references {
                    let file = project.appendingPathComponent(reference.file)
                    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                          let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                    let answer = try classifier.closedProbability(of: picture)
                    compared += 1
                    worst = max(worst, abs(answer - reference.closed))
                    if (answer > 0.5) != (reference.label == "closed") { disagreements += 1 }
                }
                check("model: Swift gives Python's answers on real pictures", compared >= 10 && worst < 0.01,
                      String(format: "%d pictures, largest difference %.6f", compared, worst))
                check("model: every one of them matches its label", compared >= 10 && disagreements == 0,
                      "\(disagreements) wrong")
            } catch {
                check("model: reference answers read", false, "\(error)")
            }
        } else {
            print("SKIP  model against Python's answers (no --reference given)")
        }

        print(allPassed ? "RESULT: all checks passed" : "RESULT: FAILED")
        return allPassed
    }
}
