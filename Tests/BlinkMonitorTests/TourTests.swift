import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

/// The demo's tour of its own screens: the list, without starting the app.
@Suite("The tour")
struct TourTests {

    @Test("--open= takes the window names the docs give, and those only")
    func windowNames() throws {
        #expect(Set(WindowName.allCases.map(\.rawValue))
                    == ["setup", "live-view", "history", "settings", "blink-break", "routine-timer"])
        let guide = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(guide.contains("--open=" + ["setup", "live-view", "history", "settings", "blink-break", "routine-timer"].joined(separator: ",")))
    }

    @Test("A fixed order: the panel, the blink break, History, Settings tab by tab, Live View, the panel")
    func order() {
        let steps = Tour.plan().map(\.step.rawValue)
        #expect(steps == ["panel", "blink-break", "history", "history-earlier-week", "history-back", "settings-general",
                          "settings-blink-rate", "settings-breaks", "settings-routines", "settings-privacy", "settings-about",
                          "live-view", "end"])
        #expect(Set(steps).count == steps.count, "each step has a name of its own in the log")
    }

    @Test("The pace sets every length, and stays between a flicker and a freeze")
    func pace() {
        #expect(Tour.pace(asked: nil) == Tour.usualPace && Tour.pace(asked: "nonsense") == Tour.usualPace)
        #expect(Tour.pace(asked: "6") == 6 && Tour.pace(asked: "0") == 1 && Tour.pace(asked: "600") == 30)
        #expect(Tour.plan(pace: 2).allSatisfy { $0.seconds == $0.step.beats * 2 })
        // At the usual pace the whole tour is about a minute: short enough to film in one take.
        #expect((60...90).contains(Tour.length()))
        #expect(Tour.length(pace: 1) * 4 == Tour.length(pace: 4))
    }
}
