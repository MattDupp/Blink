import AppKit
import SwiftUI
import BlinkCore

/// Renders every screen of the app to a PNG, with made-up data:
///
///     BlinkMonitor --snapshots=<folder>          (or: make snapshots)
///
/// Two uses. While designing: a screen can be looked at, changed and looked at again
/// without clicking through the app. For the README: screenshots that are always up to
/// date and never show anyone's face (the camera is not opened).
///
/// Everything made up lives in this file (`SampleData`). The app's own types know nothing
/// about screenshots: they are simply started from a state instead of from the camera.
@MainActor
enum Snapshots {

    static func render(to folder: URL) -> Bool {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("Cannot create \(folder.path): \(error.localizedDescription)")
            return false
        }

        // A fixed moment (a Friday afternoon), so the pictures do not change from day to day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 16, minute: 42)) ?? Date()

        var written = 0
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let normal = SampleData.model(now: now, low: false)
            let low = SampleData.model(now: now, low: true)

            let screens: [(String, AnyView)] = [
                ("panel", AnyView(MenuPanelView(model: normal, history: normal.history, reminders: normal.reminders,
                                               loginItem: normal.loginItem, now: now, actions: PanelActions()))),
                ("panel-low", AnyView(MenuPanelView(model: low, history: low.history, reminders: low.reminders,
                                                   loginItem: low.loginItem, now: now, actions: PanelActions()))),
                ("history", AnyView(HistoryView(history: normal.history, reminders: normal.reminders, now: now))),
                ("welcome", AnyView(WelcomeView(start: {}))),
                ("diagnostics", AnyView(DiagnosticsView(model: normal, captures: normal.captures))),
            ]
            for (name, view) in screens {
                let file = folder.appendingPathComponent("\(name)-\(suffix).png")
                if write(view, appearance: appearance, to: file) {
                    written += 1
                    print("Wrote \(file.path)")
                } else {
                    print("FAILED \(file.lastPathComponent)")
                }
            }
        }
        return written == 10
    }

    /// Lays a view out off screen, at twice the resolution, and saves it.
    private static func write(_ view: AnyView, appearance name: NSAppearance.Name, to file: URL) -> Bool {
        let appearance = NSAppearance(named: name)
        let framed = view
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(18)

        let hosting = NSHostingView(rootView: framed)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)

        // The view has to live in a window to be drawn with its controls.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))   // let SwiftUI finish its first pass

        let scale = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                            pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return false }
        return PNGFile.write(image, to: file)
    }
}

/// A made-up but plausible week of use: the same at every run, never written to disk.
@MainActor
enum SampleData {

    /// The app after a week, watching. `low`: the last hours were a stretch of deep
    /// concentration, and the rate is under the threshold.
    static func model(now: Date, low: Bool) -> MonitorModel {
        var live = LiveState()
        live.faceFound = true
        live.eyeRects = [CGRect(x: 760, y: 430, width: 130, height: 130), CGRect(x: 1030, y: 425, width: 130, height: 130)]
        live.probability = 0.02
        live.counters.ratePerMinute = low ? 6 : 13
        live.counters.blinksLastMinute = low ? 6 : 13
        live.counters.totalBlinks = 148
        live.counters.longClosures = 3
        live.counters.observedSeconds = 11 * 60 + 42
        live.counters.lastBlinkSeconds = 0.167

        var timings = StageTimings.Summary()
        timings.findEyes = 6.4
        timings.crop = 1.3
        timings.model = 0.7
        timings.total = 8.6
        timings.worstTotal = 21.5
        timings.framesPerSecond = 30
        timings.analysedShare = 1

        let initial = MonitorModel.InitialState(live: live, curve: curve(), timings: timings,
                                                cameraNote: "The camera picture is left out of screenshots.")
        // A store of their own: the screenshots must not depend on the user's settings.
        return MonitorModel(settings: .temporary(), history: HistoryController(minutes: minutes(now: now, low: low)),
                            initial: initial)
    }

    /// Ten seconds of the model's answers, with three blinks in them.
    static func curve() -> Curve {
        let blinkStarts = [91.4, 94.9, 98.1]
        var curve = Curve()
        curve.now = 100
        curve.samples = (0..<300).map { frame in
            let time = 90 + Double(frame) / 30
            let inBlink = blinkStarts.contains { time >= $0 && time < $0 + 0.13 }
            let edge = blinkStarts.contains { (time >= $0 - 0.034 && time < $0) || (time >= $0 + 0.13 && time < $0 + 0.165) }
            return TraceSample(time: time, probability: inBlink ? 0.98 : (edge ? 0.45 : 0.02))
        }
        curve.blinks = blinkStarts.map { Blink(start: $0, end: $0 + 0.16) }
        return curve
    }

    /// One working week of minutes: mornings at a healthy rate, fewer blinks after lunch.
    static func minutes(now: Date, low: Bool, calendar: Calendar = .current) -> [MinuteRecord] {
        var seed: UInt64 = 20_261_120
        func random() -> Double {                 // a small fixed generator: same data every time
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var sample: [MinuteRecord] = []
        let today = calendar.startOfDay(for: now)
        for back in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  !calendar.isDateInWeekend(day) else { continue }
            let dayLevel = [15.5, 13.0, 14.5, 11.5, 14.0, 16.0, 13.5][back % 7]
            for hour in [9, 10, 11, 13, 14, 15, 16, 17] {
                for minute in 0..<60 {
                    guard let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                          start < now, random() > 0.12 else { continue }      // away now and then
                    // Deep concentration after lunch: fewer blinks. (`low`: it lasts until now.)
                    let deep = hour == 14 || hour == 15 || (low && hour >= 16)
                    let focus = deep ? 0.58 : (hour == 10 ? 0.85 : 1.0)
                    let rate = max(2, dayLevel * focus + (random() - 0.5) * 9)
                    let watched = 48 + random() * 12
                    sample.append(MinuteRecord(start: start, observedSeconds: watched,
                                               blinks: Int((rate * watched / 60).rounded())))
                }
            }
        }
        // The last three minutes decide "low or not": state them, do not leave them to chance.
        let minuteNow = MinuteRecord.minuteStart(of: now)
        sample.removeAll { $0.start >= minuteNow.addingTimeInterval(-180) }
        for back in [3, 2, 1] {
            sample.append(MinuteRecord(start: minuteNow.addingTimeInterval(-Double(back) * 60),
                                       observedSeconds: 58, blinks: low ? 6 : 13))
        }
        return sample
    }
}
