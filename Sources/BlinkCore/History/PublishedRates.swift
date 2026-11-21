import Foundation

/// A paper this app takes a number or a claim from.
public struct Citation: Equatable, Identifiable {

    /// How the paper was read when `docs/BLINK-RATE.md` was written. An abstract can leave
    /// out limits the article states, so the app says which it was.
    public enum Reading: Equatable {
        case fullText
        case abstract
    }

    public let id: String
    /// "Doughty 2001": how the app and the docs name it.
    public let name: String
    public let title: String
    public let journal: String
    /// The paper's permanent address.
    public let link: URL
    public let reading: Reading
    /// What it found, in one or two sentences. Every figure the app repeats is in here.
    public let finding: String
}

/// A range of blink rates that studies report for one thing a person can be doing.
public struct StudyRange: Equatable {

    public enum Situation: Equatable, CaseIterable {
        /// Reading, or working at a screen.
        case atScreen
        /// Looking straight ahead, without talking.
        case lookingAhead
        case inConversation
    }

    /// Where a rate sits against a range.
    public enum Position: Equatable {
        case below, inside, above
    }

    public let situation: Situation
    /// Blinks a minute.
    public let lower: Double
    public let upper: Double
    public let source: Citation

    /// The two ends belong to the range.
    public func position(of rate: Double) -> Position {
        rate < lower ? .below : (rate > upper ? .above : .inside)
    }
}

/// What published studies say about how often healthy adults blink: the ONE place the app
/// keeps a number that comes from a study. Every window reads it from here; a test fails if
/// a view types one of these numbers itself. `docs/BLINK-RATE.md` is the research behind it
/// (48 sources, read on 2026-11-21).
///
/// WHAT THE NUMBERS ARE, AND ARE NOT:
///   - They are TYPICAL ranges, not ideal ones. No study gives a rate that is "enough" for
///     the eye surface, so nothing here is a target and the app never words it as one.
///   - They are ranges of the AVERAGES of groups. One healthy person can sit well outside
///     them: at a screen, 51 volunteers ranged from 0.4 to 18.9 (Freudenthaler 2003).
///   - They never set your limit. The limit comes from your own reference and your floor
///     (`Baseline`). The ranges are shown next to it, and that is all they do.
public enum PublishedRates {

    // MARK: The ranges

    /// Doughty's review of 75 years of studies: the 95% interval of the group averages, for
    /// each of three situations. It is the one published range for "reading and video
    /// display terminal use", and six newer screen studies average 5.3 to 14.9, so inside
    /// it or just above.
    public static let atScreen = StudyRange(situation: .atScreen, lower: 1.4, upper: 14.4, source: doughty2001)
    public static let lookingAhead = StudyRange(situation: .lookingAhead, lower: 8.0, upper: 21.0, source: doughty2001)
    public static let inConversation = StudyRange(situation: .inConversation, lower: 10.5, upper: 32.5, source: doughty2001)

    /// In the order they are shown: the one that matches what the app watches comes first.
    public static let ranges = [atScreen, lookingAhead, inConversation]

    /// The top of a scale that holds every range: the next multiple of five.
    public static var scaleTop: Double {
        ((ranges.map(\.upper).max() ?? 0) / 5).rounded(.up) * 5
    }

    // MARK: Your own rate against the screen range

    /// A week is only placed against the range once it has this many rated minutes: an
    /// hour, as for a drift (`Baseline.driftMinutes`).
    public static let minutesToCompare = 60

    public struct Comparison: Equatable {
        /// Blinks a minute over everything that was watched.
        public let rate: Double
        public let position: StudyRange.Position

        public init(rate: Double, position: StudyRange.Position) {
            self.rate = rate
            self.position = position
        }
    }

    /// Where these days sit against the range for screen work, or nil when too little was
    /// recorded to say. The app only watches someone at a screen, so that is the range
    /// that compares like with like.
    public static func comparison(of summary: DaySummary) -> Comparison? {
        guard summary.ratedMinutes >= minutesToCompare, let rate = summary.ratePerMinute else { return nil }
        return Comparison(rate: rate, position: atScreen.position(of: rate))
    }

    // MARK: The starting floor

    /// A tear film that holds for about this long is the usual case in healthy eyes: 24
    /// students averaged 10.3 s, from 3.4 to 22.9 (Chidi-Egboka 2023).
    public static let usualBreakUpSeconds = 10.0

    /// The floor a new install starts with, in blinks a minute.
    ///
    /// The first version started at 10. The studies say that is above what an average
    /// healthy adult does at a screen (5.3 complete blinks a minute in Freudenthaler 2003),
    /// so a person with an ordinary rate would have been told "Low" most of the time,
    /// before and after their own reference was measured.
    ///
    /// This number is ARITHMETIC, not a finding. The eye surface is covered while the next
    /// blink comes before the tear film breaks up (the Ocular Protection Index, Ousler
    /// 2008). With evenly spaced blinks and the usual break-up time, that is 60 / 10 = 6 a
    /// minute. Break-up times differ between people and blinks are not evenly spaced, so it
    /// is a starting point to adjust, like the 10 it replaces.
    public static var startingFloor: Int {
        Int((60 / usualBreakUpSeconds).rounded())
    }

    // MARK: The sources

    /// The whole review, with its table of studies and their limits.
    public static let review = URL(string: "https://github.com/MattDupp/blink-monitor/blob/main/docs/BLINK-RATE.md")!

    /// The papers behind what the app says, in the order the Sources tab lists them.
    public static let sources = [doughty2001, bentivoglio1997, freudenthaler2003, chidiEgboka2023,
                                 wang2025, ousler2008, kim2021, tfos2023]

    static let doughty2001 = Citation(
        id: "doughty-2001", name: "Doughty 2001",
        title: "Consideration of three types of spontaneous eyeblink activity in normal humans: during reading and video display terminal use, in primary gaze, and while in conversation",
        journal: "Optometry and Vision Science 78(10)",
        link: doi("10.1097/00006324-200110000-00011"), reading: .abstract,
        finding: "A review of 75 years of studies. Group averages run from 1.4 to 14.4 blinks a minute while reading or at a screen, 8 to 21 looking straight ahead in silence, and 10.5 to 32.5 in conversation. It calls stating one value for the blink rate inappropriate.")

    static let bentivoglio1997 = Citation(
        id: "bentivoglio-1997", name: "Bentivoglio 1997",
        title: "Analysis of blink rate patterns in normal subjects",
        journal: "Movement Disorders 12(6)",
        link: doi("10.1002/mds.870120629"), reading: .abstract,
        finding: "150 healthy people, filmed. On average 17 blinks a minute at rest, 26 in conversation and 4.5 while reading: the task changes the rate more than age does.")

    static let freudenthaler2003 = Citation(
        id: "freudenthaler-2003", name: "Freudenthaler 2003",
        title: "Characteristics of spontaneous eyeblink activity during video display terminal use in healthy volunteers",
        journal: "Graefe's Archive for Clinical and Experimental Ophthalmology 241(11)",
        link: doi("10.1007/s00417-003-0786-6"), reading: .abstract,
        finding: "51 healthy volunteers, complete blinks only, counted from video: the closest study to what this app counts. At a screen 5.3 a minute on average, and from 0.4 to 18.9 from one person to the next. No link between a person's rate and their tear film.")

    static let chidiEgboka2023 = Citation(
        id: "chidi-egboka-2023", name: "Chidi-Egboka 2023",
        title: "Blink rate measured in situ decreases while reading from printed text or digital devices, regardless of task duration, difficulty, or viewing distance",
        journal: "Investigative Ophthalmology & Visual Science 64(2)",
        link: doi("10.1167/iovs.64.2.14"), reading: .fullText,
        finding: "24 students wearing an eye-tracking headset. 10.7 blinks a minute while reading, the same on paper, laptop and phone, against 32.4 in conversation. Their tear film held for 10.3 seconds on average, from 3.4 to 22.9.")

    static let wang2025 = Citation(
        id: "wang-2025", name: "Wang 2025",
        title: "Blink completeness and rate in dry eye disease: an investigator-masked, prospective registry-based, cross-sectional, prognostic study",
        journal: "Contact Lens and Anterior Eye 48(3)",
        link: doi("10.1016/j.clae.2025.102369"), reading: .abstract,
        finding: "453 people. The share of incomplete blinks predicted dry eye disease. The blink rate was linked to nothing measured on the eye surface. This app counts complete blinks and does not measure incomplete ones.")

    static let ousler2008 = Citation(
        id: "ousler-2008", name: "Ousler 2008",
        title: "The Ocular Protection Index",
        journal: "Cornea 27(5)",
        link: doi("10.1097/ICO.0b013e31816583f6"), reading: .abstract,
        finding: "The eye surface is covered while the next blink comes before the tear film breaks up. With evenly spaced blinks and a tear film that holds 10 seconds, that is 6 blinks a minute: where this app's floor starts. That figure is arithmetic, not a finding.")

    static let kim2021 = Citation(
        id: "kim-2021", name: "Kim 2021",
        title: "Therapeutic benefits of blinking exercises in dry eye disease",
        journal: "Contact Lens and Anterior Eye 44(3)",
        link: doi("10.1016/j.clae.2020.04.014"), reading: .abstract,
        finding: "54 people with dry eye symptoms were asked to do ten seconds of blinking exercises every 20 minutes for four weeks, and 41 finished. Symptoms eased and incomplete blinks fell from 54% to 34%. There was no control group.")

    static let tfos2023 = Citation(
        id: "tfos-2023", name: "TFOS Lifestyle 2023",
        title: "TFOS Lifestyle: Impact of the digital environment on the ocular surface",
        journal: "The Ocular Surface 28",
        link: doi("10.1016/j.jtos.2023.04.004"), reading: .fullText,
        finding: "The Tear Film and Ocular Surface Society's review of screens and the eye. Fewer and less complete blinks are the main mechanism it names. Five studies of blink reminders all raised the rate, and three of them eased symptoms, in the short term only.")

    private static func doi(_ identifier: String) -> URL {
        URL(string: "https://doi.org/" + identifier)!
    }
}
