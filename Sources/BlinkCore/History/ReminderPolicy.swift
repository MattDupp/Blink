import Foundation

/// Decides when to tell you that you are not blinking enough.
///
/// Two things would make reminders useless: firing on too little evidence (one quiet
/// minute while you think) and firing again and again. So:
///   - the rate is taken over the last 3 minutes, and only if your eyes were really
///     watched for at least 2 of them (no reminder for the time you were away);
///   - after a reminder, none for 5 minutes, however low the rate stays;
///   - none at all while you have snoozed them.
public struct ReminderPolicy {

    public var windowMinutes = 3
    public var minimumObservedSeconds = 120.0
    public var cooldownSeconds = 300.0
    public private(set) var lastReminder: Date?
    public private(set) var snoozedUntil: Date?

    public init() {}

    /// Blinks per minute over the last minutes, or nil when too little was watched.
    public func recentRate(records: [MinuteRecord], now: Date) -> Double? {
        let oldest = MinuteRecord.minuteStart(of: now).addingTimeInterval(-Double(windowMinutes) * 60)
        let recent = records.filter { $0.start >= oldest && $0.start <= now }
        let observed = recent.reduce(0) { $0 + $1.observedSeconds }
        guard observed >= minimumObservedSeconds else { return nil }
        return Double(recent.reduce(0) { $0 + $1.blinks }) / observed * 60
    }

    /// No reminder before `date` (nil: reminders are back at once).
    public mutating func snooze(until date: Date?) {
        snoozedUntil = date
    }

    public func isSnoozed(at now: Date) -> Bool {
        snoozedUntil.map { now < $0 } ?? false
    }

    /// True when a reminder should be shown now; it then starts the 5-minute pause.
    public mutating func reminderDue(rate: Double?, threshold: Double, now: Date) -> Bool {
        guard let rate, rate < threshold, !isSnoozed(at: now) else { return false }
        if let lastReminder, now.timeIntervalSince(lastReminder) < cooldownSeconds { return false }
        lastReminder = now
        return true
    }
}
