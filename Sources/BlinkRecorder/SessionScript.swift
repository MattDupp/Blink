import Foundation

/// The two answers the model will learn to give. These words become the folder names
/// on disk and, later, the model's two outputs.
enum EyeLabel: String {
    case open
    case closed
}

/// One step of a recording session: the voice says `instruction`, then every eye picture
/// taken during the next few seconds is saved with `label`.
struct Phase {
    let label: EyeLabel
    /// A short name for the pose, written next to every picture. It lets us ask later
    /// "on which poses does the model fail?" instead of only "how often does it fail?".
    let variant: String
    let instruction: String
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
enum SessionScript {

    /// After the voice stops, wait this long before recording: you need a moment to get
    /// into the pose, and a picture taken mid-movement would carry the wrong label.
    static let settleSeconds = 1.0

    /// How long each pose is recorded.
    static let recordSeconds = 3.0

    /// Keep one frame out of three (10 pictures a second instead of 30). Two frames taken
    /// 33 ms apart are almost the same picture: keeping both adds disk space and training
    /// time, not information.
    static let saveEveryNthFrame = 3

    static let phases: [Phase] = [
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
}
