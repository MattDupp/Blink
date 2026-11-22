import SwiftUI
import BlinkCore

/// What the app says about look-away breaks, in one place.
///
/// Every sentence is built from the numbers you chose. The first version wrote "20
/// seconds" into the banner and into Settings; with a break of 40 seconds that would be
/// wrong in two places at once. `BreakWordsTests` holds this.
enum BreakWords {

    /// "40 seconds", "1 minute", "1 min 30 s".
    static func length(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60, rest = seconds % 60
        if rest == 0 { return Format.count(minutes, "minute") }
        return "\(minutes) min \(rest) s"
    }

    static func length(minutes: Int) -> String { length(seconds: minutes * 60) }

    /// The seconds or minutes of this kind of break, in words.
    static func length(of kind: BreakKind, in plan: BreakPlan) -> String {
        kind == .long ? length(minutes: plan.longMinutes) : length(seconds: plan.breakSeconds)
    }

    // MARK: The banner

    static func bannerTitle(_ kind: BreakKind, plan: BreakPlan) -> String {
        switch kind {
        case .short: return "Look far away for \(length(of: .short, in: plan))"
        case .long: return "Long break: leave the screen for \(length(of: .long, in: plan))"
        }
    }

    static func bannerBody(_ kind: BreakKind, screenMinutes: Int) -> String {
        let atTheScreen = "You have been at the screen for \(Format.count(screenMinutes, "minute"))."
        switch kind {
        case .short:
            return "\(atTheScreen) Pick something across the room, or out of the window. A sound says when it is over."
        case .long:
            return "\(atTheScreen) Stand up and walk away: only time away from the screen counts. A sound says when it is done."
        }
    }

    // MARK: Settings

    /// The plan in one or two sentences.
    static func summary(_ plan: BreakPlan) -> String {
        let short = "Every \(length(minutes: plan.workMinutes)) at the screen, look far away for \(length(of: .short, in: plan))."
        guard let every = plan.longEvery else { return short }
        return "\(short) After \(every == 1 ? "each one" : "\(every) of these"), leave the screen for \(length(of: .long, in: plan))."
    }

    /// A ready-made setting, by what it does.
    static func summary(_ preset: BreakPlan.Preset) -> String {
        let plan = preset.plan
        var text = "\(preset.rawValue): every \(plan.workMinutes) min, \(length(of: .short, in: plan))"
        if let every = plan.longEvery { text += ", \(length(of: .long, in: plan)) away after \(every)" }
        return text
    }

    // MARK: The panel

    /// The break in progress.
    static func running(_ current: ScreenBreakController.Current) -> String {
        switch current.kind {
        case .short:
            return "Look far away for \(length(seconds: current.seconds)). A sound says when it is over."
        case .long:
            let whole = current.seconds / 60
            return "Long break: \(current.awaySeconds / 60) of \(whole) min away from the screen."
        }
    }

    /// Time at the screen, while no break runs.
    static func atTheScreen(minutes: Int, nextIsLong: Bool) -> String {
        "At the screen for \(minutes) min without a break" + (nextIsLong ? ". The next one is the long break" : "")
    }

    /// Today's breaks; nil when there is nothing to say yet.
    static func tally(_ tally: BreakTally) -> String? {
        guard tally.taken + tally.skipped + tally.cutShort > 0 else { return nil }
        var text = "Breaks today: \(tally.taken)"
        var details: [String] = []
        if tally.away > 0 { details.append("\(tally.away) away from the screen") }
        if tally.long > 0 { details.append("\(tally.long) long") }
        if !details.isEmpty { text += " (\(details.joined(separator: ", ")))" }
        if tally.skipped > 0 { text += ", \(tally.skipped) skipped" }
        if tally.cutShort > 0 { text += ", \(tally.cutShort) cut short" }
        return text
    }
}
