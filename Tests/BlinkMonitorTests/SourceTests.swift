import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

/// Rules about the source itself.
@Suite("The app's source")
struct SourceTests {

    /// The project folder (two levels above this file's folder).
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("No window keeps the moment it was created as 'now'")
    func noStoredNow() throws {
        // `var now = Date()` as a property of a view is the moment the VIEW was made - and a
        // view is made once. That froze the panel's clock at the app's launch (see Moment).
        // A property is declared four spaces in; a local constant inside a function, eight.
        let stored = try Regex(#"^    (var|let) \w+(: Date)? = Date\(\)"#).anchorsMatchLineEndings()
        var offenders: [String] = []
        for folder in ["Sources/BlinkMonitor", "Sources/BlinkUI"] {
            let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains(stored) { offenders.append(file.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "a stored Date() in: \(offenders)")
    }

    /// Every line of the app's own sources that holds text between quotes, outside the
    /// comment lines: "Name.swift:12" and the text from its first quote to its last.
    private func quotedLines() throws -> [(place: String, quoted: Substring)] {
        var lines: [(String, Substring)] = []
        for folder in ["Sources/BlinkMonitor", "Sources/BlinkUI"] {
            let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.drop { $0 == " " }
                    guard !trimmed.hasPrefix("//"), let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\"") else { continue }
                    lines.append(("\(file.lastPathComponent):\(number + 1)", line[first...last]))
                }
            }
        }
        return lines
    }

    @Test("A number that a rule decides is read from the rule, never typed into a sentence")
    func noTypedRuleNumber() throws {
        // Each of these stood in a sentence beside the constant that decides it (review of
        // 25 November 2026): `Baseline`, `ReminderPolicy`, `ProofTest`, `BlinkBreak`,
        // `BlinkStats`, `SessionPace`. Change the constant, and the sentence went on saying
        // the old number. The sentences now read them (`ReminderWords`, `CalibrationWords`).
        let typed = ["70%", "3 h at", "3 hours over", "for 3 minutes", "5, 15, 30", "for 20 minutes", "10 ticks",
                     "fewer than 8", "ten slow", "ten times", "after 20 seconds", "three seconds each", "Fifteen seconds",
                     "under 30 minutes"]
        let offenders = try quotedLines().flatMap { line in
            typed.filter { line.quoted.contains($0) }.map { "\(line.place) \($0)" }
        }
        #expect(offenders.isEmpty, "a number typed by hand in: \(offenders)")
    }

    @Test("The reminder's waits are said as a list, from the policy's numbers")
    func reminderWaits() {
        #expect(ReminderWords.waits(minutes: [5, 15, 30, 60]) == "5, 15, 30, then 60 minutes")
        #expect(ReminderWords.waits(minutes: [5]) == "5 minutes")
        #expect(ReminderWords.waits(minutes: []) == "")
        #expect(ReminderWords.waits == ReminderWords.waits(minutes: [5, 15, 30, 60]))
        #expect(ReminderWords.withSound == "the first two")
    }

    @Test("No retired word comes back in what a user reads")
    func noRetiredWord() throws {
        // One thing, one name (the audit of 22 November 2026 found six names for two
        // numbers). Names in the code may stay: only text between quotes is read, and
        // comment lines are skipped.
        let retired = ["your reference", "the reference", "Never under", "your floor", "nudge", "on target", "trainer",
                       "analysed)", "is analysed", "blinks per minute", "Blinks per minute", "Snooze", "watched\"",
                       "...\"", "Session \\(", " Session\"",
                       // Tier 3 of the same audit.
                       "\"--\"", "Show the Files", "Show Data File", "Go Back to the Model", "forget to.\"", "read as an abstract",
                       "Your own\"",
                       // The app's name until 24 November 2026. It also holds "Blink Monitor - ",
                       // the old window titles.
                       "Blink Monitor"]
        let offenders = try quotedLines().flatMap { line in
            retired.filter { line.quoted.contains($0) }.map { "\(line.place) \($0)" }
        }
        #expect(offenders.isEmpty, "a retired word in: \(offenders)")
    }

    @Test("A window's main button is made with mainButton(), so that the pictures draw it tinted")
    func mainButtons() throws {
        // `.keyboardShortcut(.defaultAction)` alone is drawn grey in a picture, which is
        // rendered in a window that is never in front (`MainButton.swift`).
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources/BlinkMonitor"), includingPropertiesForKeys: nil)
        for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
            if try String(contentsOf: file, encoding: .utf8).contains(".keyboardShortcut(.defaultAction)") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "a main button made by hand in: \(offenders)")
    }

    @Test("A text style is asked through textStyle(), so that Larger text reaches it; a small control through smallControl()")
    func textStyles() throws {
        // `.font(.callout)` on a view stays 12 points whatever the switch says. Text drawn
        // inside a chart (`context.draw`) keeps its size on purpose, and is let through.
        let style = try NSRegularExpression(pattern: #"\.font\(\.(largeTitle|title|title2|title3|headline|body|callout|subheadline|footnote|caption|caption2)\b"#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources/BlinkMonitor"), includingPropertiesForKeys: nil)
        for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let drawn = line.contains("context.") || (number > 0 && lines[number - 1].contains("let label = Text("))
                let styled = style.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                if (styled && !drawn) || line.contains(".controlSize(.small)") { offenders.append("\(file.lastPathComponent):\(number + 1)") }
            }
        }
        #expect(offenders.isEmpty, "a text style or a small control that Larger text cannot reach: \(offenders)")
    }

    @Test("No window types a number that comes from a study: they are read from PublishedRates")
    func noStudyNumberInAView() throws {
        // The ends of the ranges that are not whole numbers, as a window would write them,
        // and the sentence the first version had in Settings, which had no source.
        let ends = PublishedRates.ranges.flatMap { [$0.lower, $0.upper] }.filter { $0 != $0.rounded() }
        #expect(ends.count >= 4)
        let figures = ends.map { String(format: "%.1f", $0) }
        // A figure standing alone: not the tail of 21.4, nor the head of 1.45.
        let typed = try Regex("(^|[^0-9.])(" + figures.map { $0.replacingOccurrences(of: ".", with: "\\.") }
            .joined(separator: "|") + ")($|[^0-9])").anchorsMatchLineEndings()
        var offenders: [String] = []
        for folder in ["Sources/BlinkMonitor", "Sources/BlinkRecorder", "Sources/BlinkUI"] {
            let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for case let file as URL in files ?? FileManager.DirectoryEnumerator() where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains(typed) || text.contains("15 to 20 times a minute") { offenders.append(file.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "a study's number typed in: \(offenders)")
    }

    @Test("Learning the usual rate says what is left: the time, and the second day")
    func calibrationWords() {
        func line(hours: Double, days: Int) -> String {
            CalibrationWords.line(Baseline.Calibration(watchedSeconds: hours * 3600, days: days), limit: 10)
        }
        // The first day: time is missing, and so is a second day.
        #expect(line(hours: 1 + 20.0 / 60, days: 1)
                == "Learning your usual rate: 1 h 20 min of 3 h, over 2 days. It can finish tomorrow. Until then the limit is 10 a minute.")
        // The first day, a long one: only the second day is missing. It no longer stops at "50%".
        #expect(line(hours: 5, days: 1).contains("all on one day") && line(hours: 5, days: 1).contains("finishes tomorrow"))
        // The second day: only time is missing.
        #expect(line(hours: 2.5, days: 2).contains("2 h 30 min of 3 h. 30 min to go."))
    }

    @Test("A failure to start is a sentence for a person: no error text, no command")
    func startFailureWords() {
        for failure in [StartFailure.model(trainedHere: true), .model(trainedHere: false), .noCamera, .camera, .cameraLeftOff] {
            let sentence = failure.sentence
            #expect(!sentence.contains("make ") && !sentence.contains("--") && !sentence.contains("Error"))
            #expect(sentence.contains("counted"))
        }
        #expect(StartFailure.model(trainedHere: true).offersSetup && !StartFailure.camera.offersSetup)
        // With no rate to show, the panel writes the state where the number would be.
        #expect(MonitorStatus.paused(until: nil).headline == "Paused")
        #expect(MonitorStatus.noFace.headline == "No face")
        #expect(MonitorStatus.watching(rate: nil).headline == "Starting")
        #expect(MonitorStatus.watching(rate: 13).headline == nil)
        #expect(MonitorStatus.watching(rate: 13).explanation(limit: 10) == "Your rate over the last minute. Your limit is 10.")
    }

    @Test("Deleting the recordings and the model also removes the captures saved from Live View")
    @MainActor func deleteIncludesCaptures() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("blink-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sessions = base.appendingPathComponent("sessions", isDirectory: true)
        let captures = base.appendingPathComponent("captures", isDirectory: true)
        for folder in [sessions, captures.appendingPathComponent("20270101-100000-free", isDirectory: true)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let model = MonitorModel(preferences: .temporary(), place: DataPlace(folder: base))
        try await model.deleteModelAndRecordings(sessions: sessions, own: true, captures: captures)
        #expect(!FileManager.default.fileExists(atPath: sessions.path))
        #expect(!FileManager.default.fileExists(atPath: captures.path))
        // The record buttons belong to whoever started the app with a folder for captures.
        #expect(!Options.developerTools)
    }

    @Test("A blink break is left out of the count: no watched time and no blink, but its blinks are still reported")
    func exerciseLeftOut() throws {
        var eyes = DemoEyes()
        let pipeline = MonitorPipeline()
        pipeline.setLiveView(true)                 // report every frame
        var updates: [MonitorUpdate] = []
        pipeline.onUpdate = { updates.append($0) }
        func run(from start: Double, seconds: Double) {
            for frame in 0..<Int(seconds * 30) {
                let time = start + Double(frame) / 30
                pipeline.process(eyes.reading(at: time), time: time)
            }
        }
        run(from: 1000, seconds: 60)
        let before = try #require(updates.last?.live.counters)
        #expect(before.observedSeconds > 55 && before.totalBlinks > 5)

        eyes.pace = .exercise                      // slow, full blinks
        pipeline.setExercise(true)
        updates = []
        run(from: 1060, seconds: 40)
        let during = try #require(updates.last?.live.counters)
        #expect(during.observedSeconds == before.observedSeconds && during.totalBlinks == before.totalBlinks)
        #expect(updates.compactMap(\.event).count >= 5)          // the exercise still hears them
        #expect(updates.compactMap(\.completedMinute).allSatisfy { $0.observedSeconds <= 60 })

        eyes.pace = .usual
        pipeline.setExercise(false)
        run(from: 1100, seconds: 10)
        #expect(try #require(updates.last?.live.counters).observedSeconds > before.observedSeconds + 9)
    }
}
