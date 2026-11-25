import Foundation
import Combine
import SwiftUI
import Testing
import BlinkCore
import BlinkUI
@testable import BlinkMonitor

/// What the app says about published studies: typical, never ideal.
@Suite("Words about the studies")
struct StudyWordsTests {

    private let positions: [(Double, StudyRange.Position)] = [(0.9, .below), (11.8, .inside), (21.3, .above)]

    @Test("Wherever a week falls, the sentence gives the range and never calls a rate ideal, healthy or normal")
    func comparisonSentences() {
        let judgements = ["ideal", "healthy", "normal", "should", "too little", "too much", "warning"]
        for (rate, position) in positions {
            let sentence = PublishedRates.Comparison(rate: rate, position: position).sentence
            #expect(sentence.contains(PublishedRates.atScreen.span), "the range is missing: \(sentence)")
            #expect(sentence.contains(String(format: "%.1f", rate)))
            for word in judgements {
                #expect(!sentence.lowercased().contains(word), "'\(word)' in: \(sentence)")
            }
        }
        // Under the range, the likely reason is the counting, and the sentence says where to look.
        #expect(PublishedRates.Comparison(rate: 0.9, position: .below).sentence.contains("Live View"))
        // Above it, the ordinary reason is talking.
        #expect(PublishedRates.Comparison(rate: 21.3, position: .above).sentence.contains(PublishedRates.inConversation.span))
        #expect(PublishedRates.Comparison(rate: 11.8, position: .inside).sentence.contains("not a target"))
    }

    @Test("The ranges are written with one decimal, dropped when it is zero")
    func spans() {
        #expect(PublishedRates.atScreen.span == "1.4 to 14.4")
        #expect(PublishedRates.lookingAhead.span == "8 to 21")
        #expect(PublishedRates.inConversation.span == "10.5 to 32.5")
        #expect(PublishedRates.caption.contains("a target") && PublishedRates.caption.contains(PublishedRates.atScreen.source.name))
        #expect(PublishedRates.caption.contains(PublishedRates.experiment.source.name))
        #expect(PublishedRates.experiment.span == "10 worse, 20 fine")
    }

    @Test("A limit above the usual rate is explained, with a way out that exists")
    func limitAboveUsual() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let ordinary = PublishedRates.limitAboveUsual(reference: Reference(rate: 7.2, measuredOn: day, minutes: 200),
                                                      limit: 10, canLower: true)
        #expect(ordinary.contains("7.2") && ordinary.contains("limit of 10") && ordinary.contains("ordinary at a screen"))
        #expect(ordinary.contains("lower the lowest limit"))

        // Under what studies report: the counting is the likely reason, not the person.
        let missed = PublishedRates.limitAboveUsual(reference: Reference(rate: 0.9, measuredOn: day, minutes: 200),
                                                    limit: 4, canLower: false)
        #expect(missed.contains("Live View") && !missed.contains("ordinary"))
        #expect(missed.contains("cannot go lower") && !missed.contains("lower the lowest limit"))
    }
}
