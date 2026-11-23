import Foundation

/// How much work the app spends on reading the eyes: one choice, three levels.
///
/// WHAT A LEVEL CHANGES is one thing: how often the eyes are looked for. Finding them
/// (Apple's Vision) is most of what a frame costs: MEASURED 2026-11-23, once the cutting
/// and the model had been made lighter, 326 of the 413 million instructions a second.
/// At every level every frame is still cut and shown to the model, so every level looks
/// at every picture the camera takes. What differs is how old the squares are that the
/// eye pictures are cut from.
///
/// WHAT A LEVEL DOES NOT CHANGE: what happens when nobody is there (`FrameSchedule`'s
/// rules for an empty chair), so no level is slower to notice a face coming back; how
/// the eye pictures are made; the counting rules.
///
/// Nothing here speaks of the graphics processor: measured the same day, the app keeps
/// it busy under 1% of the time at every level (0.05% to 0.75% over the passes).
public enum Effort: String, CaseIterable, Sendable {
    /// The eyes are looked for on one frame in 3, and what was read in squares the eyes
    /// had left is forgotten (`FrameSchedule.strayBeyond`).
    case light
    /// On every other frame: what the app has done since its first release.
    case standard
    /// On every frame, as while a session is recorded.
    case thorough

    /// The rhythm of the level. `standard` is `FrameSchedule()` as it is: someone who
    /// never chose gets the counting of before the choice existed.
    public var schedule: FrameSchedule {
        var schedule = FrameSchedule()
        switch self {
        case .light:
            schedule.searchEvery = 3
            schedule.strayBeyond = 0.35
        case .standard:
            break
        case .thorough:
            schedule.searchEvery = 1
        }
        return schedule
    }

    /// How many times a second the eyes are looked for, with a camera of 30 pictures a second.
    public var searchesASecond: Int { 30 / schedule.searchEvery }

    /// What a level was measured to cost and to count.
    public struct Measured: Equatable, Sendable {
        /// Of the blinks a person marked in the recordings, how many the level counted.
        public let found: Int
        public let marked: Int
        /// Blinks it counted where none was marked.
        public let falseBlinks: Int
        /// The pipeline's work, in millions of instructions a second.
        public let instructions: Double
        /// Its share of one processor core, in percent, and the processor's power for it,
        /// in milliwatts.
        public let processor: Double
        public let milliwatts: Double
    }

    /// MEASURED 2026-11-23 on three captures replayed from their whole frames at the
    /// camera's pace (`BlinkReplay --cost=model --effort=<level>`, 121 s, 80 blinks
    /// marked), MacBook Pro M5 Pro on battery, the model trained in the app. Each level
    /// was passed twice, forty minutes apart; the numbers here are the mean of the two.
    /// The cost is the pipeline's alone: what the replay spends reading its movie (47
    /// million instructions a second, 1.7% of a core, 6 mW) is taken off.
    ///
    ///                first pass                  second pass
    ///     light      319 M   6.7%   36 mW        324 M   8.0%   37 mW
    ///     standard   417 M   8.4%   46 mW        423 M  10.2%   50 mW
    ///     thorough   714 M  13.3%   75 mW        727 M  17.2%   94 mW
    ///
    /// HOW TO READ THEM. The instructions of two passes are within 2% of each other. The
    /// share of a core and the power are not: thorough read 13.3% and 17.2%, depending on
    /// which cores macOS chose and how fast it ran them. So the levels are compared by
    /// their work, and that comparison holds: light did 23.5% and 23.4% less than
    /// standard, thorough 71% and 72% more. In the app the same work takes a larger share
    /// of a core than in the replay (`EyeLocator.usual`), and the camera adds its own:
    /// these numbers compare the levels, they are not the app's bill.
    ///
    /// The one blink `standard` counts where none is marked is a real one, on frames
    /// where one eye was hidden: the marks do not cover those.
    public var measured: Measured {
        switch self {
        case .light: return Measured(found: 70, marked: 80, falseBlinks: 0, instructions: 322, processor: 7.4, milliwatts: 37)
        case .standard: return Measured(found: 72, marked: 80, falseBlinks: 1, instructions: 420, processor: 9.3, milliwatts: 48)
        case .thorough: return Measured(found: 73, marked: 80, falseBlinks: 0, instructions: 720, processor: 15.3, milliwatts: 85)
        }
    }

    /// The level's work next to the standard's: -0.23 is about a quarter less, 0.71 about 70% more.
    public var workAgainstStandard: Double {
        measured.instructions / Effort.standard.measured.instructions - 1
    }
}
