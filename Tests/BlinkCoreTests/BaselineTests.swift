import Foundation
import Testing
@testable import BlinkCore

/// The personal baseline, and above all what it must NOT do: follow a decline.
@Suite("Personal baseline")
struct BaselineTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 09:00 UTC on a Monday.
    private let monday = Date(timeIntervalSince1970: 1_800_262_800)

    /// `hours` hours of full minutes at `rate` blinks a minute, from 09:00 on day `day`.
    private func minutes(day: Int, hours: Double, rate: Int) -> [MinuteRecord] {
        (0..<Int(hours * 60)).map {
            MinuteRecord(start: monday.addingTimeInterval(Double(day) * 86_400 + Double($0) * 60),
                         observedSeconds: 60, blinks: rate)
        }
    }

    private var twoGoodDays: [MinuteRecord] { minutes(day: 0, hours: 2, rate: 16) + minutes(day: 1, hours: 2, rate: 16) }
    private var later: Date { monday.addingTimeInterval(40 * 86_400) }

    // MARK: Calibration

    @Test("Calibration needs three hours AND two days: one long day is not enough")
    func calibration() {
        let oneLongDay = Baseline.calibration(records: minutes(day: 0, hours: 5, rate: 16), calendar: calendar)
        #expect(oneLongDay.days == 1 && !oneLongDay.isComplete && oneLongDay.progress == 0.5)

        let twoShortDays = Baseline.calibration(records: minutes(day: 0, hours: 0.5, rate: 16)
                                                + minutes(day: 1, hours: 1, rate: 16), calendar: calendar)
        #expect(twoShortDays.days == 2 && !twoShortDays.isComplete && twoShortDays.progress == 0.5)

        #expect(Baseline.calibration(records: twoGoodDays, calendar: calendar).isComplete)
        #expect(Baseline.calibration(records: [], calendar: calendar).progress == 0)
    }

    @Test("Minutes too short to have a rate do not count towards calibration")
    func calibrationIgnoresUnratedMinutes() {
        let glimpses = (0..<600).map {
            MinuteRecord(start: monday.addingTimeInterval(Double($0) * 60), observedSeconds: 10, blinks: 2)
        }
        #expect(Baseline.calibration(records: glimpses, calendar: calendar).watchedSeconds == 0)
        #expect(Baseline.measure(records: glimpses, now: later, calendar: calendar) == nil)
    }

    @Test("The reference is the median: a few extreme minutes do not move it")
    func median() throws {
        var records = twoGoodDays
        records += (0..<10).map {
            MinuteRecord(start: monday.addingTimeInterval(2 * 86_400 + Double($0) * 60), observedSeconds: 60, blinks: 60)
        }
        let reference = try #require(Baseline.measure(records: records, now: later, calendar: calendar))
        #expect(reference.rate == 16 && reference.minutes == 250 && reference.measuredOn == later)
        #expect(Baseline.medianRate(of: []) == nil)
        #expect(Baseline.medianRate(of: minutes(day: 0, hours: 1, rate: 10) + minutes(day: 1, hours: 1, rate: 20)) == 15)
    }

    @Test("Nothing is adopted before calibration is complete")
    func noEarlyReference() {
        #expect(Baseline.adopt(existing: nil, records: minutes(day: 0, hours: 2, rate: 16), now: later, calendar: calendar) == nil)
    }

    // MARK: The drift trap

    @Test("A month of decline does not move the reference, nor the limit")
    func referenceDoesNotFollowADecline() throws {
        let reference = try #require(Baseline.adopt(existing: nil, records: twoGoodDays, now: monday, calendar: calendar))
        #expect(reference.rate == 16)
        let limit = Baseline.limit(reference: reference, automatic: true, floor: 8)
        #expect(limit == 11)                                       // 70% of 16

        // Four weeks, each a little lower than the one before: 14, 12, 10, 8 a minute.
        var kept = reference
        for (week, rate) in [14, 12, 10, 8].enumerated() {
            let declining = minutes(day: 7 * (week + 1), hours: 3, rate: rate) + minutes(day: 7 * (week + 1) + 1, hours: 3, rate: rate)
            kept = try #require(Baseline.adopt(existing: kept, records: declining, now: later, calendar: calendar))
        }
        #expect(kept == reference)
        #expect(Baseline.limit(reference: kept, automatic: true, floor: 8) == limit)
    }

    @Test("The decline is reported instead: 8 a minute against a reference of 16 is 50% less")
    func driftIsReported() throws {
        let reference = Reference(rate: 16, measuredOn: monday, minutes: 240)
        let lastWeek = minutes(day: 28, hours: 3, rate: 8)
        #expect(try #require(Baseline.drift(reference: reference, recent: lastWeek)) == 0.5)
        #expect(try #require(Baseline.drift(reference: reference, recent: minutes(day: 28, hours: 3, rate: 20))) == -0.25)
        #expect(try #require(Baseline.drift(reference: reference, recent: lastWeek)) > Baseline.driftWorthSaying)
    }

    @Test("A drift needs an hour of minutes: one quiet moment is not a trend")
    func driftNeedsEvidence() {
        let reference = Reference(rate: 16, measuredOn: monday, minutes: 240)
        #expect(Baseline.drift(reference: reference, recent: minutes(day: 28, hours: 0.5, rate: 4)) == nil)
        #expect(Baseline.drift(reference: reference, recent: []) == nil)
    }

    @Test("Measuring again is a proposal, and one that lowers the reference says so")
    func remeasuringLowerIsFlagged() throws {
        let reference = Reference(rate: 16, measuredOn: monday, minutes: 240)
        let lowWeek = minutes(day: 28, hours: 2, rate: 10) + minutes(day: 29, hours: 2, rate: 10)
        let lower = try #require(Baseline.proposal(current: reference, records: lowWeek, now: later, calendar: calendar))
        #expect(lower.measured.rate == 10 && lower.lowers && lower.current == reference)

        let highWeek = minutes(day: 28, hours: 2, rate: 18) + minutes(day: 29, hours: 2, rate: 18)
        let higher = try #require(Baseline.proposal(current: reference, records: highWeek, now: later, calendar: calendar))
        #expect(!higher.lowers)

        let first = try #require(Baseline.proposal(current: nil, records: highWeek, now: later, calendar: calendar))
        #expect(!first.lowers)
        #expect(Baseline.proposal(current: reference, records: minutes(day: 28, hours: 1, rate: 10), now: later, calendar: calendar) == nil)
    }

    // MARK: The limit

    @Test("The limit: 70% of the reference, never under the floor, the floor alone when manual")
    func limit() {
        let usual = Reference(rate: 20, measuredOn: monday, minutes: 240)
        #expect(Baseline.limit(reference: usual, automatic: true, floor: 10) == 14)
        #expect(Baseline.limit(reference: usual, automatic: false, floor: 10) == 10)
        #expect(Baseline.limit(reference: nil, automatic: true, floor: 10) == 10)

        // A reference measured while already blinking too little: the floor holds.
        let alreadyLow = Reference(rate: 9, measuredOn: monday, minutes: 240)
        #expect(Baseline.limit(reference: alreadyLow, automatic: true, floor: 10) == 10)
    }

    // MARK: Insights

    @Test("Rates by hour of the day, with nothing said about an hour barely watched")
    func ratesByHour() {
        // 09:00-10:00 at 16, 10:00-11:00 at 8, and five minutes after 11:00.
        let records = minutes(day: 0, hours: 1, rate: 16)
            + (0..<60).map { MinuteRecord(start: monday.addingTimeInterval(3600 + Double($0) * 60), observedSeconds: 60, blinks: 8) }
            + (0..<5).map { MinuteRecord(start: monday.addingTimeInterval(7200 + Double($0) * 60), observedSeconds: 60, blinks: 2) }
        let rates = Insights.ratesByHour(records: records, calendar: calendar)
        #expect(rates.count == 24)
        #expect(rates[9] == 16 && rates[10] == 8 && rates[11] == nil && rates[3] == nil)

        let lowest = Insights.lowestHours(records: records, calendar: calendar)
        #expect(lowest.map(\.hour) == [10, 9])
    }

    @Test("The heat map has one row per day asked for, in that order")
    func heatMap() {
        let records = minutes(day: 0, hours: 1, rate: 16) + minutes(day: 1, hours: 1, rate: 8)
        let days = [monday, monday.addingTimeInterval(86_400), monday.addingTimeInterval(2 * 86_400)]
            .map { calendar.startOfDay(for: $0) }
        let map = Insights.heatMap(records: records, days: days, calendar: calendar)
        #expect(map.count == 3 && map.allSatisfy { $0.count == 24 })
        #expect(map[0][9] == 16 && map[1][9] == 8 && map[2].allSatisfy { $0 == nil })
    }

    @Test("Follow my own rate: the floor that puts the limit at 70% of the usual rate, never under 1")
    func floorFollowing() {
        let usual = Reference(rate: 7.2, measuredOn: Date(timeIntervalSince1970: 0), minutes: 200)
        #expect(Baseline.limitAboveUsual(reference: usual, limit: 10))
        let floor = Baseline.floorFollowing(reference: usual)
        #expect(floor == 5)
        let limit = Baseline.limit(reference: usual, automatic: true, floor: floor)
        #expect(limit == 5 && !Baseline.limitAboveUsual(reference: usual, limit: limit))
        #expect(Baseline.floorFollowing(reference: Reference(rate: 0.9, measuredOn: usual.measuredOn, minutes: 200)) == 1)
    }
}
