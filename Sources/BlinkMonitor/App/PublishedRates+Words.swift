import Foundation
import BlinkCore

/// How the app words what studies report. `PublishedRates` (in BlinkCore) holds the numbers
/// and their sources; this is the only place that turns them into sentences.
///
/// THE RULE OF THESE WORDS: the ranges are what is TYPICAL, never what is ideal, healthy or
/// normal, and never a target. No study gives a rate that is enough (`docs/BLINK-RATE.md`),
/// and the app is not a medical device: it reports what studies found and stops there.
extension StudyRange {

    /// The two ends, as the app writes a range: "8 to 21".
    var span: String {
        "\(Self.written(lower)) to \(Self.written(upper))"
    }

    /// The row's name in the strip.
    var situationName: String {
        switch situation {
        case .atScreen: return "Reading, or at a screen"
        case .lookingAhead: return "Looking ahead, in silence"
        case .inConversation: return "In conversation"
        }
    }

    /// A rate as the ranges write it: one decimal, dropped when it is zero.
    static func written(_ rate: Double) -> String {
        rate == rate.rounded() ? String(format: "%.0f", rate) : String(format: "%.1f", rate)
    }
}

extension PublishedRates {

    /// Said under the strip, wherever it is shown.
    static var caption: String {
        "Averages of groups of healthy adults (\(atScreen.source.name)). People differ a lot, and no study gives a rate that is enough: these are typical ranges, not targets."
    }

    /// Said after a comparison in the History window, which has no room for the list.
    static let whereTheSourcesAre = "The sources are in Settings."

    /// Said in Settings when the limit sits above the user's own usual rate
    /// (`Baseline.limitAboveUsual`): what will happen, why it is nothing to worry about,
    /// and the way out. `canLower`: the floor is not yet as low as its control goes.
    static func limitAboveUsual(reference: Reference, limit: Int, canLower: Bool) -> String {
        var sentences = [String(format: "By the app's count you usually blink %.1f times a minute, under this limit of \(limit): it will say Low most of the time.", reference.rate)]
        switch atScreen.position(of: reference.rate) {
        case .inside:
            sentences.append("That rate is ordinary at a screen: studies report \(atScreen.span).")
        case .below:
            sentences.append("That is under what studies report at a screen (\(atScreen.span)). The app counts complete blinks only and can miss some: Live View shows what it sees.")
        case .above:
            break
        }
        sentences.append(canLower ? "To follow your own rate, lower Never under." : "Never under is as low as it goes.")
        return sentences.joined(separator: " ")
    }
}

extension PublishedRates.Comparison {

    /// One or two sentences that place the user's week against the range for screen work.
    /// Outside the range is said plainly, with the ordinary reasons for it and no alarm:
    /// the camera misses blinks, and talking raises the rate.
    var sentence: String {
        let screen = PublishedRates.atScreen
        switch position {
        case .inside:
            return String(format: "This week: %.1f blinks a minute, inside what studies report for people reading or at a screen (\(screen.span)). That range is typical, not a target.", rate)
        case .below:
            return String(format: "This week the app counted %.1f blinks a minute, under what studies report at a screen (\(screen.span)). It counts complete blinks only, and can miss some: Live View shows what it sees.", rate)
        case .above:
            return String(format: "This week: %.1f blinks a minute, more than studies report at a screen (\(screen.span)). Talking raises the rate: in conversation they report \(PublishedRates.inConversation.span).", rate)
        }
    }
}

extension Citation {

    /// "read as an abstract": said next to each source, because an abstract can leave out
    /// limits that the article states.
    var readAs: String {
        switch reading {
        case .fullText: return "read in full"
        case .abstract: return "read as an abstract"
        }
    }
}
