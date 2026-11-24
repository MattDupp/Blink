import Foundation
import BlinkCore

/// What Settings says about the effort (`Effort`): what each level does, what it was
/// measured to cost and to count. Every number in a sentence is read from
/// `Effort.measured`, so that a new measurement changes the words with it.
enum EffortWords {

    static let row = "Effort"

    static func name(_ effort: Effort) -> String {
        switch effort {
        case .light: return "Light"
        case .standard: return "Standard"
        case .thorough: return "Thorough"
        }
    }

    /// What the level does, what it costs next to Standard, and how many of the marked
    /// blinks it counted: for a lower level, how many fewer, in so many words.
    static func detail(_ effort: Effort) -> String {
        let measured = effort.measured, standard = Effort.standard.measured
        let counted = "In the recordings it was tested on, it counted \(measured.found) of \(Format.count(measured.marked, "blink"))"
        switch effort {
        case .light:
            return "Looks for your eyes \(effort.searchesASecond) times a second, and forgets what it read while your head moved fast. "
                + "About \(share(effort)) less processor work than Standard. \(counted), where Standard counted \(standard.found)."
        case .standard:
            return "Looks for your eyes \(effort.searchesASecond) times a second: what Blink does unless you choose otherwise. \(counted)."
        case .thorough:
            return "Looks for your eyes in every picture of the camera, \(effort.searchesASecond) times a second. "
                + "About \(share(effort)) more processor work than Standard. \(counted), where Standard counted \(standard.found)."
        }
    }

    /// How the choice sits with Pause and with the two ways of resting.
    static let whileResting = "While counting is paused or rests, the camera is off and nothing is spent, whatever the effort."

    /// "25%", "70%": the difference with Standard, to the nearest five.
    static func share(_ effort: Effort) -> String {
        let percent = Int((abs(effort.workAgainstStandard) * 20).rounded()) * 5
        return "\(percent)%"
    }
}
