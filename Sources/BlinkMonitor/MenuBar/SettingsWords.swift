import SwiftUI
import BlinkCore
import BlinkUI

// What the Settings window says, gathered here so that its tabs hold only their views.

/// The questions people ask after a few days, answered where they look for the version.
/// Each answer says what the app does, checked against its code, and nothing about health.
enum GoodToKnow {
    static let all: [(question: String, answer: String)] = [
        ("Does it count someone else's blinks?",
         "It reads one face: the largest in view, which is the one at the keyboard. Someone behind you is not counted. Someone who sits in your place is: the app does not know whose eyes they are."),
        ("Does it work during a video call?",
         "Yes. macOS lets several apps use the camera together, and the call does not see what Blink does. For no reminders meanwhile, use Quiet in the panel, or Quiet during calls in General."),
        ("New glasses, a new desk, a new camera?",
         "Your model learned your eyes as they looked when you recorded them. After a change, test it under Model. If it counts fewer than \(ProofTest.passMark) of \(ProofTest.ticks), add a recording there."),
        ("Why is my rate lower than what I read elsewhere?",
         "The app counts complete blinks only, and people blink less at a screen than in conversation. What it compares with is your own usual rate."),
        ("Can I leave it running all day?",
         "Yes: that is what it is for. Pause turns the camera off whenever you want, and it rests by itself when the screen sleeps."),
    ]
}

/// "Send a Test Reminder", by what macOS allows. A test with notifications off did
/// nothing at all, and the first one made macOS ask its question with no warning.
enum TestReminderWords {
    static let send = "Send a Test Reminder"
    static let openSettings = "Open Notification Settings"
    static let refused = "Notifications are off for Blink, so a test has nothing to show. "
        + "Allow them in System Settings > Notifications > Blink, then send the test."
    static let asksFirst = "macOS first asks whether Blink may show notifications: choose Allow."

    /// The sentence beside the button. `usual`: what the test shows when it can.
    static func detail(_ usual: String, notifications: ReminderController.Notifications) -> String {
        switch notifications {
        case .allowed: return usual
        case .unknown: return usual + " " + asksFirst
        case .refused: return refused
        }
    }
}

/// What the app says about the choice of a camera (`CameraChoice`).
enum CameraWords {
    static func detail(inUse name: String?, macHasLid: Bool = true) -> String {
        "Automatic uses the Mac's own camera, and another one when that sends no picture for "
            + "\(Int(CameraChoice.silenceBeforeFallback)) seconds\(macHasLid ? ", as with the lid closed" : ""). "
            + "Your model learned your eyes on one camera: after changing, test it again under Model."
            + (name.map { " In use: \($0)." } ?? "")
    }

    /// In the panel, after Automatic moved to another camera.
    static func moved(to name: String) -> String {
        "The Mac's own camera sent no picture, so Blink is using “\(name)”. "
            + "Your model learned your eyes on another camera: test it again in Settings > Model."
    }
}

/// The project's pages. The app itself connects to nothing: these open in the browser.
enum ProjectLinks {
    static let home = URL(string: "https://github.com/MattDupp/Blink")!
    static let problems = URL(string: "https://github.com/MattDupp/Blink/issues")!
    static let newVersion = URL(string: "https://github.com/MattDupp/Blink/releases/latest")!
}

/// What each erasing action of Settings asks before it acts (`Confirm`): what goes, in
/// the user's words, and that it cannot be undone.
enum EraseWords {
    static func history(startingLimit: Int) -> Confirm.Question {
        Confirm.Question(title: "Erase the history?",
                         text: "Every recorded minute is erased, and your usual rate measured from them. "
                             + "The limit goes back to \(startingLimit) until it is measured again. This cannot be undone.",
                         button: "Erase")
    }

    static let routineLog = Confirm.Question(
        title: "Erase the routine log?",
        text: "What you did with your routines is erased: today's and this week's marks start again. "
            + "The routines and their times stay. This cannot be undone.",
        button: "Erase")

    static let breakLog = Confirm.Question(
        title: "Erase the break log?",
        text: "The breaks you took or skipped, the blink breaks you finished and the blink reminders shown are erased: "
            + "History no longer counts them. Your history of blinks stays. This cannot be undone.",
        button: "Erase")

    static let eyeNotes = Confirm.Question(
        title: "Erase your eye notes?",
        text: "Every answer you gave to the evening question is erased, and its row in History is empty again. This cannot be undone.",
        button: "Erase")

    static func captures(_ count: Int) -> Confirm.Question {
        Confirm.Question(title: "Erase the captures from Live View?",
                         text: "\(Format.count(count, "capture")) of your eyes, saved with Live View's record buttons. This cannot be undone.",
                         button: "Erase")
    }

    static func recordingsAndModel(_ what: String) -> Confirm.Question {
        Confirm.Question(title: "Delete the recordings and the model?", text: what, button: "Delete")
    }

    /// Not an erasure of anything recorded, but it cannot be undone either: same question.
    static let choices = Confirm.Question(
        title: "Reset every setting to its default?",
        text: "The switches and numbers of General, Blink Rate and Breaks go back to how they were on the first day, and the camera to Automatic. "
            + "Your usual rate, your history, your model, your routines and Start at login stay as they are. This cannot be undone.",
        button: "Reset")

    static let startAgain = Confirm.Question(
        title: "Start again?",
        text: "The recordings and the model are deleted, then setup opens to record your eyes anew. "
            + "Nothing is counted until it is done. This cannot be undone.",
        button: "Delete and Start Again")

    static func everything(_ records: [KeptRecord]) -> Confirm.Question {
        Confirm.Question(
            title: "Delete everything and quit?",
            text: "The recordings of your eyes, your model, \(KeptRecord.names(records)) and every setting are removed from this Mac, "
                + "and Blink quits. Afterwards, move Blink itself to the Trash. This cannot be undone.",
            button: "Delete Everything and Quit")
    }
}
