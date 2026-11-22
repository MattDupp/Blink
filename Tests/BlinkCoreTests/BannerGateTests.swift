import Foundation
import Testing
@testable import BlinkCore

/// The one gate every banner asks, on moments written by hand.
@Suite("The gate every banner asks")
struct BannerGateTests {

    private let nine = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { nine.addingTimeInterval(minutes * 60) }

    @Test("Nothing interrupts a look-away break, a blink break, a timer or the setup")
    func busy() {
        let gate = BannerGate()
        for kind in BannerGate.Kind.allCases {
            #expect(gate.mayShow(kind, now: nine))
            #expect(!gate.mayShow(kind, busy: .init(blinkBreak: true), now: nine))
            #expect(!gate.mayShow(kind, busy: .init(timer: true), now: nine))
            #expect(!gate.mayShow(kind, busy: .init(setup: true), now: nine))
        }
        // "Look far away" must not be covered by eye drops or "time to blink"...
        #expect(!gate.mayShow(.routine, busy: .init(lookAwayBreak: true), now: nine))
        #expect(!gate.mayShow(.blink, busy: .init(lookAwayBreak: true), now: nine))
        // ...but the break's own banner is what announces it.
        #expect(gate.mayShow(.screenBreak, busy: .init(lookAwayBreak: true), now: nine))
    }

    @Test("Two minutes at least between any two banners, whatever their kinds")
    func gap() {
        var gate = BannerGate()
        gate.shown(at: at(0))                     // a routine's banner at 9:00
        #expect(!gate.mayShow(.blink, now: at(0.5)))
        #expect(!gate.mayShow(.routine, now: at(1.9)))
        #expect(gate.mayShow(.blink, now: at(2)))
        gate.shown(at: at(2))
        #expect(!gate.mayShow(.routine, now: at(3)))
        #expect(gate.mayShow(.routine, now: at(4)))
    }

    @Test("Due together: a break goes first, then a routine, then the blink reminder")
    func order() {
        let gate = BannerGate()
        #expect(gate.mayShow(.screenBreak, soon: [.routine, .blink], now: nine))
        #expect(!gate.mayShow(.routine, soon: [.screenBreak], now: nine))
        #expect(gate.mayShow(.routine, soon: [.blink], now: nine))
        #expect(!gate.mayShow(.blink, soon: [.routine], now: nine))
        #expect(!gate.mayShow(.blink, soon: [.screenBreak], now: nine))
    }

    @Test("Quiet holds every kind until its end, and can be ended early")
    func quiet() {
        var gate = BannerGate()
        gate.quiet(until: BannerGate.QuietLength.oneHour.end(from: nine))
        for kind in BannerGate.Kind.allCases {
            #expect(!gate.mayShow(kind, now: at(1)) && !gate.mayShow(kind, now: at(59.9)))
            #expect(gate.mayShow(kind, now: at(60)))
        }
        #expect(gate.isQuiet(at: at(30)) && !gate.isQuiet(at: at(60)))
        gate.quiet(until: nil)
        #expect(gate.mayShow(.blink, now: at(1)))
    }

    @Test("Quiet until tomorrow ends at midnight; thirty minutes is thirty minutes")
    func lengths() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let end = BannerGate.QuietLength.untilTomorrow.end(from: nine, calendar: calendar)
        #expect(end > nine && end.timeIntervalSince(nine) <= 86_400)
        #expect(calendar.startOfDay(for: end) == end)
        #expect(BannerGate.QuietLength.thirtyMinutes.end(from: nine) == at(30))
    }
}
