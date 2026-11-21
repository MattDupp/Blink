import Foundation
import Testing
@testable import BlinkCore

/// The ranges the app takes from published studies, and what is derived from them.
@Suite("Published blink rates")
struct PublishedRatesTests {

    /// 09:00 UTC on a Monday.
    private let monday = Date(timeIntervalSince1970: 1_800_262_800)

    /// `count` full minutes at `rate` blinks a minute.
    private func minutes(_ count: Int, rate: Int, watched: Double = 60) -> [MinuteRecord] {
        (0..<count).map {
            MinuteRecord(start: monday.addingTimeInterval(Double($0) * 60), observedSeconds: watched,
                         blinks: Int((Double(rate) * watched / 60).rounded()))
        }
    }

    // MARK: The ranges

    @Test("The three ranges are the ones Doughty 2001 gives, each with its source")
    func ranges() {
        // Typed a second time on purpose: a slip of the keyboard in one place fails here.
        #expect(PublishedRates.atScreen.lower == 1.4 && PublishedRates.atScreen.upper == 14.4)
        #expect(PublishedRates.lookingAhead.lower == 8.0 && PublishedRates.lookingAhead.upper == 21.0)
        #expect(PublishedRates.inConversation.lower == 10.5 && PublishedRates.inConversation.upper == 32.5)

        #expect(PublishedRates.ranges.map(\.situation) == [.atScreen, .lookingAhead, .inConversation])
        for range in PublishedRates.ranges {
            #expect(range.lower < range.upper)
            #expect(PublishedRates.sources.contains(range.source), "a range without a listed source")
        }
    }

    @Test("People blink least at a screen and most in conversation: the ranges are in that order")
    func rangesAreOrdered() {
        let ranges = PublishedRates.ranges
        for (lower, higher) in zip(ranges, ranges.dropFirst()) {
            #expect(lower.lower < higher.lower && lower.upper < higher.upper)
        }
    }

    @Test("The scale that draws the ranges holds all of them")
    func scale() {
        #expect(PublishedRates.scaleTop == 35)
        #expect(PublishedRates.ranges.allSatisfy { $0.upper <= PublishedRates.scaleTop })
    }

    @Test("A rate is below, inside or above a range, and the two ends are inside")
    func position() {
        let range = PublishedRates.atScreen
        #expect(range.position(of: 0.9) == .below)
        #expect(range.position(of: range.lower) == .inside)
        #expect(range.position(of: 6) == .inside)
        #expect(range.position(of: range.upper) == .inside)
        #expect(range.position(of: 14.5) == .above)
    }

    // MARK: Your own rate against the screen range

    @Test("A week is placed against the screen range only once an hour of it has a rate")
    func comparisonNeedsAnHour() {
        let tooShort = DaySummary(records: minutes(PublishedRates.minutesToCompare - 1, rate: 12), threshold: 6)
        #expect(PublishedRates.comparison(of: tooShort) == nil)

        // Glimpses of ten seconds add up to time watched, but none of them has a rate.
        let glimpses = DaySummary(records: minutes(600, rate: 12, watched: 10), threshold: 6)
        #expect(glimpses.observedSeconds >= 3600 && PublishedRates.comparison(of: glimpses) == nil)

        let enough = DaySummary(records: minutes(PublishedRates.minutesToCompare, rate: 12), threshold: 6)
        #expect(PublishedRates.comparison(of: enough) == PublishedRates.Comparison(rate: 12, position: .inside))
    }

    @Test("Talking all day puts a week above the screen range; a camera that misses blinks, below")
    func comparisonOutside() {
        let calls = DaySummary(records: minutes(120, rate: 24), threshold: 6)
        #expect(PublishedRates.comparison(of: calls)?.position == .above)

        let missed = DaySummary(records: minutes(120, rate: 1), threshold: 6)
        #expect(PublishedRates.comparison(of: missed)?.position == .below)
    }

    // MARK: The starting floor

    @Test("The experiment gives two rates and no more, and the floor starts at the one that did harm")
    func experimentAndFloor() {
        let experiment = PublishedRates.experiment
        #expect(experiment.worseAt == 10 && experiment.fineAt == 20)
        #expect(experiment.worseAt < experiment.fineAt)
        #expect(PublishedRates.sources.first == experiment.source, "the experiment leads the sources")
        #expect(PublishedRates.startingFloor == 10)
        // Both tested rates fit the scale the strip draws.
        #expect(experiment.fineAt <= PublishedRates.scaleTop)
    }

    @Test("A limit above your own usual rate is noticed: the app would say Low most of the time")
    func limitAboveUsual() {
        // Ordinary at a screen in the studies, and under the starting floor.
        let usual = Reference(rate: 7.2, measuredOn: monday, minutes: 200)
        let start = Baseline.limit(reference: usual, automatic: true, floor: PublishedRates.startingFloor)
        #expect(start == 10 && Baseline.limitAboveUsual(reference: usual, limit: start))

        // The way out Settings names: a lower floor lets the limit follow the person.
        let lowered = Baseline.limit(reference: usual, automatic: true, floor: 5)
        #expect(lowered == 5 && !Baseline.limitAboveUsual(reference: usual, limit: lowered))

        // Somebody who blinks more than the floor is not told anything.
        let more = Reference(rate: 16, measuredOn: monday, minutes: 200)
        #expect(!Baseline.limitAboveUsual(reference: more, limit: Baseline.limit(reference: more, automatic: true,
                                                                                floor: PublishedRates.startingFloor)))
        #expect(!Baseline.limitAboveUsual(reference: nil, limit: 10), "nothing is known before the reference is measured")
    }

    // MARK: The sources

    @Test("Every source can be opened, is listed once, and says what it found")
    func sources() {
        let sources = PublishedRates.sources
        #expect(sources.count >= 5)
        #expect(Set(sources.map(\.id)).count == sources.count)
        #expect(Set(sources.map(\.link)).count == sources.count)
        for source in sources {
            #expect(source.link.scheme == "https" && source.link.host == "doi.org", "\(source.name) has no permanent address")
            #expect(source.link.path.hasPrefix("/10."), "\(source.name): not a DOI")
            #expect(!source.name.isEmpty && !source.title.isEmpty && !source.journal.isEmpty)
            #expect(source.finding.count >= 60, "\(source.name) does not say what it found")
            #expect(!source.finding.contains("\u{2014}"), "no em dashes in what the app says")
        }
        #expect(PublishedRates.review.absoluteString.hasSuffix("docs/BLINK-RATE.md"))
    }

    @Test("The review the app links to is in the repository, and names every source the app lists")
    func reviewDocument() throws {
        let file = Fixture.projectRoot.appendingPathComponent("docs/BLINK-RATE.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        for source in PublishedRates.sources {
            #expect(text.contains(source.link.absoluteString), "\(source.name) is missing from docs/BLINK-RATE.md")
        }
        // The numbers the app shows are the ones the review gives.
        for range in PublishedRates.ranges {
            #expect(text.contains(String(format: "%.1f to %.1f", range.lower, range.upper)))
        }
    }
}
