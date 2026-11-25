import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

@Suite("The menu-bar item")
struct MenuBarMarksTests {

    @Test("The rate keeps a slot two digits wide, so the item does not move when it crosses ten")
    func fixedSlot() {
        #expect(MonitorStatus.slot("9") == "\u{2007}9")
        #expect(MonitorStatus.slot("10") == "10")
        #expect(MonitorStatus.slot(RateReadout.none).count == 2)
        #expect(MonitorStatus.watching(rate: 9).menuBarText.count == MonitorStatus.low(rate: 12, recent: 9).menuBarText.count)
        // A state that shows no rate takes no room for one.
        #expect(MonitorStatus.paused(until: nil).menuBarText.isEmpty && MonitorStatus.needsSetup.menuBarText == "!")
    }

    @Test("VoiceOver hears the app's name once, and \"Blinks a minute\" is not taken for it")
    func spokenName() {
        let paused = MonitorStatus.paused(until: nil)
        #expect(paused.spoken(paused.tooltip(limit: 10), limit: 10) == "Blink is paused")
        // No reading yet: the tooltip starts with the letters of the name, not with the name.
        let noRate = MonitorStatus.watching(rate: nil), said = noRate.tooltip(limit: 10)
        #expect(said.hasPrefix("Blinks") && noRate.spoken(said, limit: 10) == "Blink. " + said)
        #expect(MonitorStatus.watching(rate: 12.6).spoken(said, limit: 10) == "Blink. 13 blinks a minute. " + said)
    }

    @Test("Each thing going on has its symbol, and the tooltip says each in words")
    func marks() {
        #expect(MenuBarMarks().symbols.isEmpty)
        #expect(MenuBarMarks().tooltip(after: "Blink is paused") == "Blink is paused")

        let drops = MenuBarMarks.Routine(title: "Eye drops", symbol: "drop")
        var marks = MenuBarMarks(waiting: [drops])
        #expect(marks.symbols == ["drop"], "one routine shows its own symbol")
        #expect(marks.tooltip(after: "Low") == "Low. Waiting: Eye drops")

        marks.waiting.append(.init(title: "Heated eye mask", symbol: "eye"))
        marks.onBreak = true
        #expect(marks.symbols == ["eyes", "circle.fill"], "several routines share one dot")
        #expect(marks.sentences == ["Look-away break", "Waiting: Eye drops, Heated eye mask"])

        let quiet = MenuBarMarks(quietUntil: Date(timeIntervalSince1970: 1_800_000_000), timerUntil: Date(timeIntervalSince1970: 1_800_000_600))
        #expect(quiet.symbols == ["timer", "bell.slash"])
        #expect(quiet.sentences.count == 2 && quiet.sentences[0].hasPrefix("Timer until ") && quiet.sentences[1].hasPrefix("Quiet until "))
    }
}
