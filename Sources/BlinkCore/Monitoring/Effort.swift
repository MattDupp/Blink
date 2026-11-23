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
/// it busy 0.4% of the time whatever the level.
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
    /// marked), the three levels within the same half hour, MacBook Pro M5 Pro on battery,
    /// the model trained in the app. The cost is the pipeline's alone: what the replay
    /// spends reading its movie (47 million instructions a second, 1.7% of a core, 5 mW)
    /// is taken off.
    ///
    /// HOW TO READ THEM. The instructions are the same from one pass to the next, within
    /// 1%; the share of a core is not (the same pass read 10.1% and 11.3% an hour apart,
    /// depending on which cores macOS chose), so the levels are compared by their work.
    /// In the app the same work takes a larger share of a core than in the replay
    /// (`EyeLocator.usual`), and the camera adds its own: these numbers compare the
    /// levels, they are not the app's bill.
    ///
    /// The one blink `standard` counts where none is marked is a real one, on frames
    /// where one eye was hidden: the marks do not cover those.
    public var measured: Measured {
        switch self {
        case .light: return Measured(found: 70, marked: 80, falseBlinks: 0, instructions: 319, processor: 6.7, milliwatts: 36)
        case .standard: return Measured(found: 72, marked: 80, falseBlinks: 1, instructions: 417, processor: 8.4, milliwatts: 46)
        case .thorough: return Measured(found: 73, marked: 80, falseBlinks: 0, instructions: 714, processor: 13.3, milliwatts: 75)
        }
    }

    /// The level's work next to the standard's: -0.23 is about a quarter less, 0.71 about 70% more.
    public var workAgainstStandard: Double {
        measured.instructions / Effort.standard.measured.instructions - 1
    }
}
