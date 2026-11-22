import Foundation

/// Decides when to tell you that you are not blinking enough.
///
/// Two things would make reminders useless: firing on too little evidence (one quiet
/// minute while you think) and firing again and again. So:
///   - the rate is taken over the last 3 minutes, and only if your eyes were really
///     watched for at least 2 of them (no reminder for the time you were away);
///   - after a reminder, none for 5 minutes, however low the rate stays;
///   - none at all while you have snoozed them.
///
/// AND IT BACKS OFF. A reminder nobody answers is not a reason to say it louder. Many
/// people sit under the starting limit of 10 all day (`PublishedRates`: 1.4 to 14.4 is
/// typical at a screen), and the first version sent them a banner with a sound every five
/// minutes, twelve an hour, with no end. Now, while the rate stays low and nothing
/// answers, the wait grows: 5, 15, 30, then 60 minutes, and only the first two make a
/// sound. Once the rate has been above the limit for 3 minutes it starts over at 5.
/// A finished blink break is an answer: no reminder for 20 minutes after it.
public struct ReminderPolicy {

    /// What a reminder that is due may do.
    public struct Due: Equatable {
        /// With a sound: the first two of a low stretch. After that, the banner alone.
        public let sound: Bool
    }

    public var windowMinutes = 3
    public var minimumObservedSeconds = 120.0
    /// The wait after the first reminder of a low stretch.
    public var cooldownSeconds = 300.0
    /// The waits after the second, the third, and every later one.
    public static let laterWaits = [900.0, 1800.0, 3600.0]
    /// Reminders of one low stretch that make a sound.
    public static let remindersWithSound = 2
    /// Above the limit for this long, the low stretch is over: the next one starts at 5 minutes.
    public static let recoverySeconds = 180.0
    /// No reminder for this long after a blink break was done.
    public static let quietAfterBlinkBreak = 1200.0

    public private(set) var lastReminder: Date?
    public private(set) var snoozedUntil: Date?
    /// Reminders shown in the low stretch under way, none of them answered.
    public private(set) var unanswered = 0
    /// Since when the rate has been at or above the limit (nil while it is under).
    public private(set) var aboveSince: Date?
    /// A blink break was done: nothing before this.
    public private(set) var quietUntil: Date?

    public init() {}

    /// The wait in force after the last reminder shown.
    public var currentWait: Double {
        unanswered <= 1 ? cooldownSeconds : Self.laterWaits[min(unanswered - 2, Self.laterWaits.count - 1)]
    }

    /// A blink break was finished: the reminder was answered. Nothing for 20 minutes
    /// (the exercise's slow blinks are not counted as blinks, so the rate of those
    /// minutes says nothing), and the next low stretch starts over.
    public mutating func blinkBreakDone(at now: Date) {
        quietUntil = now.addingTimeInterval(Self.quietAfterBlinkBreak)
        unanswered = 0
    }

    /// Blinks per minute over the last minutes, or nil when too little was watched.
    public func recentRate(records: [MinuteRecord], now: Date) -> Double? {
        let oldest = MinuteRecord.minuteStart(of: now).addingTimeInterval(-Double(windowMinutes) * 60)
        let recent = records.filter { $0.start >= oldest && $0.start <= now }
        let observed = recent.reduce(0) { $0 + $1.observedSeconds }
        guard observed >= minimumObservedSeconds else { return nil }
        return Double(recent.reduce(0) { $0 + $1.blinks }) / observed * 60
    }

    /// The recent rate when it is under `threshold`, else nil: "are you blinking too little
    /// right now?". Computed from the minutes each time it is asked, never stored, so it
    /// cannot go stale when the threshold or the minutes change.
    public func lowRate(records: [MinuteRecord], threshold: Double, now: Date) -> Double? {
        recentRate(records: records, now: now).flatMap { $0 < threshold ? $0 : nil }
    }

    /// No reminder before `date` (nil: reminders are back at once).
    public mutating func snooze(until date: Date?) {
        snoozedUntil = date
    }

    public func isSnoozed(at now: Date) -> Bool {
        snoozedUntil.map { now < $0 } ?? false
    }

    /// Ask once a minute, with the recent rate (nil when too little was watched).
    /// Returns what to show now, or nil; a reminder returned starts the next wait.
    /// `allowed`: false while a banner may not show (`BannerGate`); a reminder that is due
    /// then waits, and its wait does not start.
    public mutating func reminder(rate: Double?, threshold: Double, now: Date, allowed: Bool = true) -> Due? {
        guard let rate else { return nil }          // away: nothing is learned either way
        guard rate < threshold else {
            let since = aboveSince ?? now
            aboveSince = since
            if now.timeIntervalSince(since) >= Self.recoverySeconds { unanswered = 0 }
            return nil
        }
        aboveSince = nil
        if isSnoozed(at: now) { return nil }
        if let quietUntil, now < quietUntil { return nil }
        if let lastReminder, now.timeIntervalSince(lastReminder) < currentWait { return nil }
        guard allowed else { return nil }
        lastReminder = now
        unanswered += 1
        return Due(sound: unanswered <= Self.remindersWithSound)
    }

    /// True when a reminder should be shown now (see `reminder`).
    public mutating func reminderDue(rate: Double?, threshold: Double, now: Date) -> Bool {
        reminder(rate: rate, threshold: threshold, now: now) != nil
    }
}
