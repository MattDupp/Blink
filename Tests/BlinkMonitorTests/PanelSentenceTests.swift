import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

@Suite("The panel's sentence")
struct PanelSentenceTests {

    @Test("A pause held by a routine's timer names the routine; an ordinary pause does not")
    func timerPause() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = MonitorStatus.paused(until: until).explanation(limit: 10, timer: "Heated eye mask")
        #expect(timed.hasPrefix("Paused for Heated eye mask, until ") && timed.contains("by itself"))
        let plain = MonitorStatus.paused(until: until).explanation(limit: 10)
        #expect(plain.hasPrefix("The camera is off until ") && plain.contains("Routines still remind you"))
        #expect(MonitorStatus.watching(rate: 12).explanation(limit: 10, timer: "Heated eye mask").contains("Your limit is 10"))
    }

    @Test("The low rate is one sentence, in the panel, on the banner and in the tooltip")
    func lowRateSaidOnce() {
        let low = MonitorStatus.low(rate: 6, recent: 7)
        #expect(LowRateWords.sentence(limit: 10) == "Under your limit of 10 over the last 3 minutes.")
        // The large number above is the last minute: the sentence gives no second rate to confuse it with.
        #expect(low.explanation(limit: 10) == "Under your limit of 10 over the last 3 minutes. Try a blink break: ten slow, full blinks.")
        #expect(low.tooltip(limit: 10) == "Low: under your limit of 10 over the last 3 minutes")
    }

    @Test("A camera that sends nothing: the lid is named only where there is one")
    func noLidWithoutALid() {
        #expect(MonitorStatus.cameraSilent.explanation(limit: 10, camera: .lid).contains("the lid closed"))
        for place in [CameraPlace.screen, .separate] {
            let said = MonitorStatus.cameraSilent.explanation(limit: 10, camera: place) + CameraNote.silentAdvice(place) + CameraNote.faceIt(place)
            #expect(!said.contains("lid"))
        }
        #expect(!CameraNote.findOne(macHasLid: false).contains("lid"))
        #expect(!CameraWords.detail(inUse: nil, macHasLid: false).contains("lid"))
        #expect(AppWords.tagline.hasSuffix("when you forget to blink."))
    }
}
