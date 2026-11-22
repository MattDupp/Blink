import Foundation

/// One step of a recording session: the voice says `instruction`, then every eye picture
/// taken during the next few seconds is saved with `label`.
public struct Phase: Equatable {
    public let label: EyeLabel
    /// A short name for the pose, written next to every picture. It lets us ask later
    /// "on which poses does the model fail?" instead of only "how often does it fail?".
    public let variant: String
    public let instruction: String
}

/// How fast a session goes.
public struct SessionPace: Equatable {
    /// After the voice stops, wait this long before recording: you need a moment to get
    /// into the pose, and a picture taken mid-movement would carry the wrong label.
    public var settleSeconds = 1.0
    /// How long each pose is recorded.
    public var recordSeconds = 3.0
    /// Keep one frame out of three (10 pictures a second instead of 30). Two frames taken
    /// 33 ms apart are almost the same picture: keeping both adds disk space and training
    /// time, not information.
    public var saveEveryNthFrame = 3
    /// The instructions are said aloud (half of a session is spent with your eyes closed).
    public var spoken = true

    public init(settleSeconds: Double = 1.0, recordSeconds: Double = 3.0, saveEveryNthFrame: Int = 3, spoken: Bool = true) {
        self.settleSeconds = settleSeconds
        self.recordSeconds = recordSeconds
        self.saveEveryNthFrame = saveEveryNthFrame
        self.spoken = spoken
    }

    /// A person in front of a camera.
    public static let usual = SessionPace()
    /// Painted eyes (the demo, the tests): they are in the pose at once and need no voice.
    public static let painted = SessionPace(settleSeconds: 0.15, recordSeconds: 0.6, saveEveryNthFrame: 1, spoken: false)

    /// The most pictures a session can hold: every pose, both eyes, every frame kept.
    public var fullSessionPictures: Int {
        Int(Double(SessionScript.phases.count) * recordSeconds * 30 / Double(saveEveryNthFrame)) * 2
    }
}

/// The recording session.
///
/// HOW THE PICTURES GET THEIR LABEL. A model learns from examples that come with the
/// right answer. Clicking "open" or "closed" on thousands of pictures by hand would take
/// hours, so we label by INSTRUCTION instead: you are told what to do, and every picture
/// taken while you do it gets that label for free.
///
/// WHY SO MANY POSES. A network learns whatever separates the two piles of pictures most
/// easily - and that is not always what we mean. If every "closed" picture were taken
/// with the head lowered, it could learn "head lowered = closed" and be useless in real
/// life. So every pose is recorded in BOTH states, and some open poses are chosen to look
/// almost closed (looking down at the keyboard, a wide smile): the only thing left that
/// tells the piles apart is the eyelid.
public enum SessionScript {

    /// Sessions to record before the first training.
    ///
    /// MEASURED (2026-11-21, `make compare`: the app's trainer on recorded sessions only,
    /// counting the 72 marked blinks of three captures, over every choice of sessions):
    /// one session found 55 to 70 of them (63 on average), two found 60 to 72 (69), three
    /// 67 to 71 (70), four 71. One session is a gamble; two are close to four on average.
    /// One person, one morning: a third session in another light is still worth its two
    /// minutes, and the test at the end of setup is what decides.
    public static let sessionsBeforeTraining = 2

    public static let phases: [Phase] = [
        Phase(label: .open, variant: "screen", instruction: "Eyes open. Look at the screen normally."),
        Phase(label: .closed, variant: "gentle", instruction: "Close your eyes gently."),

        Phase(label: .open, variant: "camera", instruction: "Eyes open. Look at the camera, above the screen."),
        Phase(label: .closed, variant: "tight", instruction: "Close your eyes tightly."),

        Phase(label: .open, variant: "keyboard", instruction: "Eyes open. Look down at the keyboard, without closing your eyes."),
        Phase(label: .closed, variant: "chin-down", instruction: "Close your eyes, and lower your chin a little."),

        Phase(label: .open, variant: "sides", instruction: "Eyes open. Look at the left edge of the screen, then the right edge."),
        Phase(label: .closed, variant: "turned", instruction: "Close your eyes, and turn your head slightly to one side."),

        Phase(label: .open, variant: "far", instruction: "Eyes open. Lean back in your chair."),
        Phase(label: .closed, variant: "far", instruction: "Close your eyes. Stay leaned back."),

        Phase(label: .open, variant: "near", instruction: "Eyes open. Come closer to the screen."),
        Phase(label: .closed, variant: "near", instruction: "Close your eyes. Stay close."),

        Phase(label: .open, variant: "smile", instruction: "Eyes open. Smile widely."),
        Phase(label: .closed, variant: "resting", instruction: "Close your eyes, relaxed, as if resting."),

        Phase(label: .open, variant: "tilt", instruction: "Eyes open. Tilt your head towards one shoulder."),
        Phase(label: .closed, variant: "tilt", instruction: "Close your eyes. Keep your head tilted."),
    ]

    /// A name for a session that starts now: its date and time, so that names sort by age.
    public static func sessionName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

/// Is a recorded session worth keeping?
///
/// Pictures are only saved while a face is in view. A session that kept far fewer than it
/// can hold was partly recorded on an empty chair, and its two piles are no longer the
/// same poses: it is recorded again, not trained on.
public enum SessionCheck {

    /// Under this share of what a session can hold, the session is recorded again.
    public static let smallestShare = 0.7

    /// The share of a full session that was saved.
    public static func share(pictures: Int, pace: SessionPace = .usual) -> Double {
        Double(pictures) / Double(max(pace.fullSessionPictures, 1))
    }

    public static func isComplete(pictures: Int, pace: SessionPace = .usual) -> Bool {
        share(pictures: pictures, pace: pace) >= smallestShare
    }
}
