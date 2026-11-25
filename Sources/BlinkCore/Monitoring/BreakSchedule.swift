import Foundation

/// The look-away breaks as you set them: how often, how long, and whether every so often
/// one of them is a long break away from the screen.
///
/// The classic rule is "every 20 minutes, look 20 feet away for 20 seconds". These are the
/// same three ideas with the numbers left to you. The app makes no claim about which
/// numbers are right for anyone.
public struct BreakPlan: Equatable, Sendable {

    public static let workRange = 1...120          // minutes between breaks
    public static let breakRange = 10...300        // seconds of a break
    public static let longEveryRange = 1...10      // short breaks before a long one
    public static let longRange = 1...30           // minutes of a long break

    /// Minutes at the screen before a break is due.
    public var workMinutes: Int
    /// Seconds of looking far away.
    public var breakSeconds: Int
    /// A long break follows this many short ones; nil: no long break.
    public var longEvery: Int?
    /// Minutes away from the screen in a long break.
    public var longMinutes: Int

    /// Values outside the ranges are brought back inside: a stored number is never trusted.
    public init(workMinutes: Int = 20, breakSeconds: Int = 20, longEvery: Int? = nil, longMinutes: Int = 5) {
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
        self.workMinutes = clamp(workMinutes, Self.workRange)
        self.breakSeconds = clamp(breakSeconds, Self.breakRange)
        self.longEvery = longEvery.map { clamp($0, Self.longEveryRange) }
        self.longMinutes = clamp(longMinutes, Self.longRange)
    }

    /// The next value of "time between breaks" when its stepper is pressed: by 1 up to 10
    /// minutes, by 5 above. The step once depended on the value alone, so that from 10
    /// one press down gave 5, and 9 to 6 could only be reached from below.
    public static func stepMinutes(_ minutes: Int, up: Bool) -> Int {
        let next: Int
        if up {
            next = minutes < 10 ? minutes + 1 : (minutes / 5 + 1) * 5
        } else {
            next = minutes <= 10 ? minutes - 1 : ((minutes - 1) / 5) * 5
        }
        return min(max(next, workRange.lowerBound), workRange.upperBound)
    }

    /// The same for the length of a break: by 5 up to a minute, by 15 above.
    public static func stepSeconds(_ seconds: Int, up: Bool) -> Int {
        let next: Int
        if up {
            next = seconds < 60 ? (seconds / 5 + 1) * 5 : (seconds / 15 + 1) * 15
        } else {
            next = seconds <= 60 ? ((seconds - 1) / 5) * 5 : ((seconds - 1) / 15) * 15
        }
        return min(max(next, breakRange.lowerBound), breakRange.upperBound)
    }

    var workSeconds: Double { Double(workMinutes) * 60 }
    var longSeconds: Double { Double(longMinutes) * 60 }

    /// Settings to start from, described by what they do.
    public enum Preset: String, CaseIterable, Sendable {
        case classic = "Classic 20-20-20"
        case longerLooks = "Longer looks"
        case shortAndOften = "Short and often"

        public var plan: BreakPlan {
            switch self {
            case .classic: return BreakPlan(workMinutes: 20, breakSeconds: 20, longEvery: nil)
            case .longerLooks: return BreakPlan(workMinutes: 20, breakSeconds: 60, longEvery: 3, longMinutes: 5)
            case .shortAndOften: return BreakPlan(workMinutes: 10, breakSeconds: 20, longEvery: 6, longMinutes: 5)
            }
        }
    }

    /// The preset these numbers are, if any. (The length of a long break that is switched
    /// off does not matter.)
    public var preset: Preset? {
        Preset.allCases.first { candidate in
            let other = candidate.plan
            return other.workMinutes == workMinutes && other.breakSeconds == breakSeconds && other.longEvery == longEvery
                && (longEvery == nil || other.longMinutes == longMinutes)
        }
    }
}

public enum BreakKind: String, Codable, Equatable, Sendable {
    /// Look far away for some seconds.
    case short
    /// Leave the screen for some minutes.
    case long
}

/// How one break ended.
public struct BreakOutcome: Equatable, Sendable {

    public enum Ending: Equatable, Sendable {
        /// No face in view for the break: you got up, turned far enough for the camera to
        /// lose your face, or the camera itself was off (the screen slept, a pause).
        case away
        /// The break ran and was not skipped, with your face still in view. The camera
        /// cannot tell where you look, so this is taken on trust and never claimed as seen.
        case onTrust
        /// You said so.
        case skipped
        /// A long break that did not reach its time away from the screen.
        case cutShort
    }

    public var kind: BreakKind
    public var ending: Ending
    /// The same absence was already counted as a break, and has now lasted long enough to
    /// be a long one: it is one break, not two.
    public var sameAbsence = false

    public init(kind: BreakKind, ending: Ending, sameAbsence: Bool = false) {
        self.kind = kind
        self.ending = ending
        self.sameAbsence = sameAbsence
    }
}

/// Which break is due, and what counts as taken.
///
/// It has no clock and no window. It is told, as often as anyone knows, "at this time a
/// face was in view" or "was not", and answers with events: a break is due, a break ended
/// this way. `time` is in seconds on any clock that keeps running while the Mac sleeps
/// (the app uses the wall clock), so a night is a long absence and not a jump.
///
/// THE RULES
/// - Time at the screen runs while a face is in view. Losing the face for less than the
///   length of a short break changes nothing: people look down, and the camera misses
///   frames.
/// - After `workMinutes` of it a break is due. It starts by itself: nothing to click, and
///   nothing to watch. A short break lasts its seconds plus a few to turn away
///   (`leadSeconds`). The app plays a sound when it ends.
/// - A break you take before one is due counts too: an absence as long as a short break
///   is a break, and starts the time at the screen again.
/// - After `longEvery` short breaks the next one is long. A long break means leaving the
///   screen, and that the camera can check: only seconds with no face count. Back early,
///   the count waits. If the time is not reached after twice its length, the break is
///   recorded as cut short and the cycle goes on: asking again and again would only teach
///   you to switch it off.
/// - An absence as long as a long break is a long break, whenever it happens.
/// - Time when nothing was observed because the screen slept is absence.
/// - Time when the app chose not to look (the camera paused by hand, or lent to the setup)
///   is not observed at all: `notObserved` forgets the stretch. An hour's call with the
///   camera paused was written down as a long break "away from the screen", which the
///   app had not seen.
public struct BreakSchedule: Sendable {

    public enum Event: Equatable, Sendable {
        /// A break has just started. `canPostpone`: it has not been put off yet.
        case due(BreakKind, canPostpone: Bool)
        case ended(BreakOutcome)
    }

    /// The break in progress.
    public struct Running: Equatable, Sendable {
        public var kind: BreakKind
        public var start: Double
        /// Seconds to look away (short) or to be away from the screen (long).
        public var length: Double
        /// Seconds with no face in view so far.
        public var away = 0.0
        public var canPostpone: Bool
        /// Since when the face has been back in view (to restart the time at the screen
        /// from there when a long break is cut short).
        var presentSince: Double?
    }

    /// A few seconds to read the banner and turn away, added to a short break.
    public static let leadSeconds = 5.0
    /// "In 5 minutes".
    public static let postponeSeconds = 300.0
    /// This share of a short break with no face in view counts as away.
    public static let awayShare = 0.6
    /// No observation for longer than this: nobody was watching, which counts as absence.
    static let silence = 3.0

    public var plan: BreakPlan
    public private(set) var running: Running?
    /// Short breaks since the last long one.
    public private(set) var sinceLong = 0

    private var clock: Double?
    private var faceInView = false
    private var lastFace: Double?
    private var workStart: Double?
    private var postponedUntil: Double?
    private var postponed = false
    /// The absence in progress has already been counted as a break of this kind.
    private var credited: BreakKind?

    public init(plan: BreakPlan = BreakPlan()) {
        self.plan = plan
    }

    /// The kind of the next break that falls due.
    public var nextKind: BreakKind {
        plan.longEvery.map { sinceLong >= $0 } == true ? .long : .short
    }

    /// Seconds at the screen since the last break: 0 during a break or an absence.
    public func screenSeconds(at time: Double) -> Double {
        guard running == nil, let workStart, let lastFace, time >= lastFace,
              time - lastFace < Double(plan.breakSeconds) else { return 0 }
        return max(0, lastFace - workStart)
    }

    /// The camera said whether a face is in view. `quiet`: breaks are not wanted now
    /// (snoozed, or switched off): one that falls due is passed over without a word.
    /// `hold`: a break that falls due waits (a blink break, a timer or the setup is
    /// under way, see `BannerGate`): it starts at the first look once the hold is over,
    /// and the time at the screen goes on counting meanwhile.
    public mutating func observe(time: Double, faceFound: Bool, quiet: Bool = false, hold: Bool = false) -> [Event] {
        step(time, face: faceFound, quiet: quiet, hold: hold)
    }

    /// Time has passed and the camera said nothing new. The app calls this once a second
    /// during a break, so that the break ends on time even if no frame arrives.
    public mutating func advance(to time: Double) -> [Event] {
        step(time, face: nil, quiet: false, hold: false)
    }

    /// Seconds until the next break falls due, while someone is at the screen and no break
    /// runs. Nil otherwise: there is nothing to count down to.
    public func secondsUntilDue(at time: Double) -> Double? {
        guard running == nil, workStart != nil, let lastFace, time >= lastFace,
              time - lastFace < Double(plan.breakSeconds) else { return nil }
        var left = plan.workSeconds - screenSeconds(at: time)
        if let postponedUntil { left = max(left, postponedUntil - time) }
        return max(0, left)
    }

    /// "Now": the next break starts at once, before it is due. It was asked for, so it
    /// cannot be put off. Nil when a break is running, or when nothing was observed yet.
    public mutating func startNow(at time: Double) -> Event? {
        guard running == nil, clock != nil else { return nil }
        let kind = nextKind
        running = Running(kind: kind, start: time,
                          length: kind == .long ? plan.longSeconds : Double(plan.breakSeconds),
                          canPostpone: false, presentSince: time)
        postponedUntil = nil
        return .due(kind, canPostpone: false)
    }

    /// "In 5 minutes": once per break. False when it was not allowed.
    public mutating func postpone(at time: Double) -> Bool {
        guard let run = running, run.canPostpone else { return false }
        running = nil
        postponed = true
        postponedUntil = time + Self.postponeSeconds
        return true
    }

    /// "Skip": the break in progress is over, and recorded as skipped.
    public mutating func skip(at time: Double) -> Event? {
        guard let run = running else { return nil }
        return .ended(finish(run, .skipped, at: time, present: true))
    }

    /// An end found more than this long after the last look is found late (the Mac
    /// slept through it): it makes no sound.
    public static let lateSeconds = 10.0
    public static func foundLate(sinceLastLook seconds: Double) -> Bool { seconds > lateSeconds }

    /// The app stopped looking on purpose (Pause, or the setup has the camera). Whatever
    /// comes next starts a new stretch: no break is credited for the time not observed,
    /// and none is recorded. The count to the long break is kept.
    public mutating func notObserved() {
        clock = nil
        running = nil
        workStart = nil
        lastFace = nil
        credited = nil
        postponedUntil = nil
        postponed = false
    }

    /// Breaks were switched off: forget the one in progress, record nothing.
    public mutating func stop() {
        running = nil
        workStart = nil
        postponedUntil = nil
        postponed = false
    }

    // MARK: - One step

    private mutating func step(_ time: Double, face: Bool?, quiet: Bool, hold: Bool) -> [Event] {
        guard let previous = clock, time >= previous else {
            // The first observation, or a clock that was set back: nothing is known about
            // the time before. Start a new stretch; the count to the long break is kept.
            // A "Later" goes too: its five minutes were counted on the old clock, and an
            // hour set back would have held the next break for an hour and five minutes.
            clock = time
            running = nil
            lastFace = nil
            workStart = nil
            credited = nil
            postponedUntil = nil
            postponed = false
            faceInView = face ?? false
            if face == true {
                lastFace = time
                workStart = time
            }
            return []
        }
        let interval = time - previous
        clock = time
        // Was anyone at the screen during the interval that just ended?
        let wasAway = interval > Self.silence || !(face ?? faceInView)
        if let face { faceInView = face }
        let present = face ?? (faceInView && !wasAway)

        var events: [Event] = []
        if var run = running {
            if wasAway { run.away += interval }
            if present, wasAway || run.presentSince == nil { run.presentSince = time }
            if !present { run.presentSince = nil }
            running = run
            if present { lastFace = time }

            switch run.kind {
            case .short:
                if time >= run.start + Self.leadSeconds + run.length {
                    let away = run.away >= Self.awayShare * run.length
                    // The screen slept through it, for as long as a long break: it was one.
                    if plan.longEvery != nil, run.away >= plan.longSeconds { run.kind = .long }
                    events.append(.ended(finish(run, away ? .away : .onTrust, at: time, present: present)))
                }
            case .long:
                if run.away >= run.length {
                    events.append(.ended(finish(run, .away, at: time, present: present)))
                } else if time >= run.start + Self.leadSeconds + 2 * run.length {
                    events.append(.ended(finish(run, .cutShort, at: time, present: present)))
                }
            }
            return events
        }

        guard face == true else { return events }

        // A face is in view. Was it gone long enough to have been a break?
        if let lastFace {
            let gap = time - lastFace
            if plan.longEvery != nil, gap >= plan.longSeconds, credited != .long {
                sinceLong = 0
                events.append(.ended(BreakOutcome(kind: .long, ending: .away, sameAbsence: credited != nil)))
            } else if gap >= Double(plan.breakSeconds), credited == nil {
                sinceLong += 1
                events.append(.ended(BreakOutcome(kind: .short, ending: .away)))
            }
            if gap >= Double(plan.breakSeconds) {
                workStart = time
                postponedUntil = nil
                postponed = false
            }
        }
        credited = nil
        lastFace = time
        let since = workStart ?? time
        workStart = since

        guard time - since >= plan.workSeconds, postponedUntil.map({ time >= $0 }) ?? true else { return events }
        if quiet {
            workStart = time          // passed over: the count starts again, nothing is recorded
            postponedUntil = nil
            postponed = false
            return events
        }
        if hold { return events }     // due, and kept waiting: nothing is forgotten
        let kind = nextKind
        running = Running(kind: kind, start: time,
                          length: kind == .long ? plan.longSeconds : Double(plan.breakSeconds),
                          canPostpone: !postponed, presentSince: time)
        postponedUntil = nil
        events.append(.due(kind, canPostpone: !postponed))
        return events
    }

    /// The break in progress is over. `present`: a face is in view at this moment.
    private mutating func finish(_ run: Running, _ ending: BreakOutcome.Ending, at time: Double, present: Bool) -> BreakOutcome {
        running = nil
        postponedUntil = nil
        postponed = false
        if run.kind == .long { sinceLong = 0 } else { sinceLong += 1 }
        if present {
            // Cut short: you have been back for a while, and that time was at the screen.
            workStart = ending == .cutShort ? (run.presentSince ?? time) : time
            lastFace = time
            credited = nil
        } else {
            // Still away: the absence goes on, and must not be counted a second time.
            workStart = nil
            credited = ending == .away || ending == .onTrust ? run.kind : nil
        }
        return BreakOutcome(kind: run.kind, ending: ending)
    }
}

/// One day's breaks, counted.
public struct BreakTally: Codable, Equatable, Sendable {

    /// The start of the day these numbers belong to.
    public var day: Date
    /// Breaks that ran to their end, away from the screen or on trust.
    public private(set) var taken = 0
    /// Of those, the ones with no face in view.
    public private(set) var away = 0
    /// Of those, the long ones.
    public private(set) var long = 0
    public private(set) var skipped = 0
    public private(set) var cutShort = 0

    public init(day: Date) {
        self.day = day
    }

    /// Counts a break on the day it ended. A new day starts from zero.
    public mutating func record(_ outcome: BreakOutcome, dayStart: Date) {
        if dayStart != day { self = BreakTally(day: dayStart) }
        switch outcome.ending {
        case .away, .onTrust:
            // One absence that grew from a short break into a long one is one break. If the
            // short one was counted yesterday, the long one is today's.
            if !outcome.sameAbsence || taken == 0 {
                taken += 1
                if outcome.ending == .away { away += 1 }
            }
            if outcome.kind == .long { long += 1 }
        case .skipped: skipped += 1
        case .cutShort: cutShort += 1
        }
    }

    /// The numbers for `dayStart`: these, or zeros when they are another day's.
    public func on(_ dayStart: Date) -> BreakTally {
        dayStart == day ? self : BreakTally(day: dayStart)
    }
}
