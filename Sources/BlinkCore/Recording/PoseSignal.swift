import Foundation

/// What the setup window shows when a closed-eye pose ends.
///
/// The end of a pose is a sound, because the eyes are closed. Someone who cannot hear it
/// (deaf, hard of hearing, or at a Mac with no sound) kept their eyes closed with nothing
/// to tell them the pose was over. A change of light is seen through closed eyelids, so
/// the window changes its brightness when the sound plays.
///
/// WHICH WAY. A dark window turns bright and comes back. A light window is already as
/// bright as the screen goes, so laying white over it changes almost nothing: it dims and
/// comes back, and the coming back is the brightening one sees (`change(windowIsDark:)`).
///
/// AFTER THE POSE, NEVER DURING IT. The screen lights the face. A window that dimmed while
/// the eyes are closed would make every closed-eye picture a little darker than the open
/// ones, and the model could learn "darker means closed" instead of the eyelid. The change
/// starts when the recording of the pose has stopped, and is over before the next begins.
///
/// NOT VERIFIED BY EYE (22 November 2026): whether the change is strong enough through
/// closed eyelids, in a lit room, was not tried by a person.
///
/// ONCE, AND SOFTLY. Light that flashes several times a second can trigger a seizure in
/// people with photosensitive epilepsy; the usual line is three flashes a second. This is
/// one slow rise and fall for a pose, and a pose lasts seconds: `shortestGap` is the
/// time from one brightening to the next, and a test holds it far above that line. With
/// Reduce Motion on in macOS there is no rise and fall at all: the window changes at once,
/// less strongly so that the page stays readable, and stays so until the next pose begins.
///
/// Only a pose with closed eyes is marked: with open eyes one sees the page. And only in
/// a recording that is spoken, which is a real one: the demo's painted eyes need no sign.
public enum PoseSignal: Equatable, Sendable {
    /// Nothing is shown.
    case none
    /// One brightening: this long up, this long held, this long down (seconds).
    case pulse(rise: Double, hold: Double, fall: Double)
    /// Reduce Motion: bright at once, and until the next pose is recorded.
    case steady

    /// Which way the window changes.
    public enum Change: Equatable, Sendable {
        /// White is laid over a dark window.
        case brighter
        /// Black is laid over a light window; its return is the brightening.
        case darker
    }

    public static func change(windowIsDark: Bool) -> Change {
        windowIsDark ? .brighter : .darker
    }

    /// How far the window changes, as the share of white or black laid over it. Never a
    /// blank screen; and the steady one leaves the next pose's words readable.
    public var strength: Double {
        switch self {
        case .none: return 0
        case .pulse: return 0.7
        case .steady: return 0.45
        }
    }

    public static func atEnd(of label: EyeLabel, pace: SessionPace, reduceMotion: Bool) -> PoseSignal {
        guard label == .closed, pace.spoken else { return .none }
        return reduceMotion ? .steady : .pulse(rise: 0.35, hold: 0.5, fall: 0.9)
    }

    /// How long the brightening lasts, from the first change to the last.
    public var seconds: Double {
        switch self {
        case .none, .steady: return 0
        case .pulse(let rise, let hold, let fall): return rise + hold + fall
        }
    }

    /// The shortest time from the start of one brightening to the start of the next: a
    /// pose is at least settled and recorded in between (the spoken instruction adds to it).
    public static func shortestGap(pace: SessionPace) -> Double {
        pace.settleSeconds + pace.recordSeconds
    }
}
