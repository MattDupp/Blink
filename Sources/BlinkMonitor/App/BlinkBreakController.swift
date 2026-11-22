import SwiftUI
import AppKit
import BlinkCore

/// Runs a blink break: counts the blinks of the exercise as the camera sees them.
///
/// The counting rule is `BlinkBreak` (in BlinkCore, tested). This class adds what a rule
/// cannot: a sound at each blink - your eyes are closed, so you cannot watch the ring -
/// and closing the window a moment after the last one.
@MainActor
final class BlinkBreakController: ObservableObject {

    /// The exercise in progress, nil when none.
    @Published private(set) var exercise: BlinkBreak?

    /// The exercise is done and has been shown as done for a moment: close its window.
    var onFinished: () -> Void = {}
    /// The last blink of the exercise was just counted.
    var onDone: () -> Void = {}

    private let countSound = NSSound(named: "Pop")
    private let doneSound = NSSound(named: "Glass")

    /// `exercise`: what the screenshots start from.
    init(exercise: BlinkBreak? = nil) {
        self.exercise = exercise
    }

    func start() {
        exercise = BlinkBreak()
    }

    func stop() {
        exercise = nil
    }

    /// Feed every event of the blink detector.
    func record(_ event: BlinkDetector.Event) {
        guard var current = exercise, !current.isDone else { return }
        let before = current.count
        current.record(event)
        guard current.count != before else { return }
        exercise = current

        guard current.isDone else {
            (countSound?.copy() as? NSSound)?.play()      // a copy: one NSSound cannot overlap itself
            return
        }
        doneSound?.play()
        onDone()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            // Still showing that same finished exercise? (It may have been closed by hand.)
            guard let self, self.exercise == current else { return }
            self.onFinished()
        }
    }
}
