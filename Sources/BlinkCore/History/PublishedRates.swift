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
/// (56 sources, read on 2026-11-21).
///
/// WHAT THE NUMBERS ARE, AND ARE NOT:
///   - They are TYPICAL ranges, not ideal ones. No rate is established as "enough" for
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

    // MARK: The experiment

    /// The one study that CHANGED the blink rate and measured the eyes afterwards (Chai
    /// 2025), and so the app's main source for what a rate does. 45 young adults with dry
    /// eye symptoms spent 30 minutes at each of two paced rates and at their own.
    public struct Experiment: Equatable {
        /// Blinks a minute after which the tear film, the redness and the symptoms were worse.
        public let worseAt: Double
        /// Blinks a minute after which they were no different from the person's own rate.
        public let fineAt: Double
        public let source: Citation
    }

    /// Two rates were tested and no other: what lies between them is not known. The people
    /// had symptoms, knew they were watched and were not at a screen, and the study has not
    /// been repeated. That is why it leads the sources and still sets nobody's limit by itself.
    public static let experiment = Experiment(worseAt: 10, fineAt: 20, source: chai2025)

    // MARK: The starting floor

    /// The floor an install starts with, in blinks a minute: the rate that did harm in the
    /// experiment. Under it, the app says "Low".
    ///
    /// For a day this branch started new installs at 6, from arithmetic on the tear film's
    /// break-up time, because healthy adults at a screen average about 5 complete blinks a
    /// minute (Freudenthaler 2003) and 10 calls many of them low. The project's author then
    /// chose the experiment over the arithmetic (2026-11-21): a measured harm at 10 outweighs
    /// a derived 6. The cost is known and handled: somebody who usually blinks less than 10
    /// times a minute is told so in Settings, with the way to lower the floor
    /// (`Baseline.limitAboveUsual`).
    public static var startingFloor: Int {
        Int(experiment.worseAt.rounded())
    }

    // MARK: The sources

    /// The whole review, with its table of studies and their limits.
    public static let review = URL(string: "https://github.com/MattDupp/blink-monitor/blob/main/docs/BLINK-RATE.md")!

    /// The papers behind what the app says, in the order the Sources tab lists them.
    /// The experiment first, then the ranges, then the rest.
    public static let sources = [chai2025, doughty2001, bentivoglio1997, freudenthaler2003, chidiEgboka2023,
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

    static let chai2025 = Citation(
        id: "chai-2025", name: "Chai 2025",
        title: "Identification of a blink frequency threshold for maintaining tear film stability in young adults with dry eye symptoms",
        journal: "Scientific Reports 15",
        link: doi("10.1038/s41598-025-26424-z"), reading: .fullText,
        finding: "The one experiment that changed the blink rate. 45 young adults with dry eye symptoms: after 30 minutes at 10 blinks a minute, paced by a sound, the tear film was less stable and the symptoms worse than after 20 a minute or their own rate. This app's floor starts at that 10. Two rates only, away from a screen, not repeated, and nothing about eyes without symptoms.")

    static let ousler2008 = Citation(
        id: "ousler-2008", name: "Ousler 2008",
        title: "The Ocular Protection Index",
        journal: "Cornea 27(5)",
        link: doi("10.1097/ICO.0b013e31816583f6"), reading: .abstract,
        finding: "The Ocular Protection Index: the eye surface is covered while the next blink comes before the tear film breaks up, and exposed when it comes later. How long a tear film holds differs from one person to the next, so the index gives no single rate for everybody.")

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
