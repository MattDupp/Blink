import Foundation

/// Should counting rest to save energy?
///
/// The app reads the camera all day and uses about a third of one processor core while it
/// does. On mains power nobody notices; on a battery it is a choice the user should have.
/// Two switches, both off unless chosen: rest on battery, and rest while Low Power Mode
/// is on. Like a pause, resting turns the camera off; unlike one, it ends by itself when
/// the reason goes.
public enum EnergyPause {

    public enum Reason: Equatable, Sendable {
        case battery, lowPower
    }

    /// Why counting rests now, or nil. Low Power Mode is named first when both hold: it
    /// is the one the user switched on by hand.
    public static func reason(onBattery: Bool, lowPower: Bool, pauseOnBattery: Bool, pauseInLowPower: Bool) -> Reason? {
        if pauseInLowPower && lowPower { return .lowPower }
        if pauseOnBattery && onBattery { return .battery }
        return nil
    }
}

/// What happened while nobody could be told: the Mac slept through the end of a pause or
/// of a routine's timer. It is marked in silence at the time, and said in the panel the
/// next time it is opened, once.
public struct WhileAway: Equatable, Sendable {
    /// A pause ended during sleep: counting is on again.
    public var pauseEnded = false
    /// The routines whose timer ended during sleep, by their titles.
    public var timersEnded: [String] = []

    public init() {}

    public var isEmpty: Bool { !pauseEnded && timersEnded.isEmpty }

    /// One sentence for each thing, in the order it matters.
    public var sentences: [String] {
        var sentences = timersEnded.map {
            "The timer of \($0) ended while the Mac was asleep. It was marked done, without its sound."
        }
        if pauseEnded { sentences.append("Your pause ended while the Mac was asleep: counting is on again.") }
        return sentences
    }
}
