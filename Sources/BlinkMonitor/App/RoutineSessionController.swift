import AppKit
import BlinkCore

/// Runs the timer of a routine that takes a while, such as a mask kept on the eyes.
///
/// Whoever is under a mask cannot see the screen, and the camera cannot see their eyes.
/// So the timer does three things a plain reminder cannot:
///   - it PAUSES THE CAMERA for its length (through `pauseCamera`): covered eyes must
///     not be read as a low blink rate or a long closure;
///   - it KEEPS THE MAC AWAKE: ten minutes without a key is enough for a Mac to go to
///     sleep, and a sleeping Mac plays no sound;
///   - it PLAYS A SOUND at the end, and marks the routine done (through `onDone`).
///
/// The rule of time is `RoutineSession` (in BlinkCore, tested): it holds the END, and is
/// compared with the clock. The `Timer` here only says "look at the clock now"; if the
/// Mac slept through it, the next look (`check`, every 20 seconds) finds the end passed.
///
/// A session is not kept across a relaunch: quit the app and the timer is gone. The
/// camera's pause, which is stored, still ends by itself at the same moment.
@MainActor
final class RoutineSessionController: ObservableObject {

    /// The timer running now, nil when none.
    @Published private(set) var session: RoutineSession?
    /// The timer that has just run to its end: shown as done for a while.
    @Published private(set) var finished: RoutineSession?

    /// Show the timer's window; close it.
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    /// Pause the camera until this moment. Answers false when it was left alone (it was
    /// already paused by the user).
    var pauseCamera: (Date) -> Bool = { _ in false }
    /// End the pause that `pauseCamera` began, if it is still that one.
    var resumeCamera: (Date) -> Void = { _ in }
    /// The timer ran to its end.
    var onDone: (RoutineSession) -> Void = { _ in }
    /// Its end was found late (the Mac slept through it): marked done with no sound and
    /// no window, so it is said in the panel.
    var onEndedLate: (RoutineSession) -> Void = { _ in }
    /// The sound of the end. Twice, a moment apart: your eyes are closed, and one short
    /// sound is easy to take for something else.
    var chime: () -> Void = {
        NSSound(named: "Glass")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { NSSound(named: "Glass")?.play() }
    }

    /// How long the window stays on "Done" before closing by itself.
    static let shownDoneSeconds = 120.0
    /// Found over more than this long after its end (the Mac slept): no sound, no window.
    static let lateSeconds = 60.0

    private var timer: Timer?
    private var awake: NSObjectProtocol?
    private var ownsPause = false

    /// What the screenshots start from: a timer shown as running, or as just ended, with
    /// no clock behind it and nothing paused.
    func show(running: RoutineSession? = nil, finished: RoutineSession? = nil) {
        session = running
        self.finished = finished
    }

    /// Starts the timer of `routine`. False when it has none, or one is already running.
    @discardableResult
    func start(_ routine: Routine, now: Date = Date()) -> Bool {
        guard session == nil, let new = RoutineSession(routine: routine, start: now) else { return false }
        finished = nil
        session = new
        ownsPause = pauseCamera(new.end)
        // "User initiated" also tells macOS not to slow this app's timers down while it
        // has no window in front (App Nap), and not to sleep while nobody types.
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                      reason: "A routine's timer is running")
        // By its length, not by the date of its end: `now` is the caller's clock (a test
        // gives one of its own), and the length is the same on every clock.
        let timer = Timer(timeInterval: new.end.timeIntervalSince(now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.app.notice("Routine timer started: \(new.routine, privacy: .public), \(Int(new.end.timeIntervalSince(now)), privacy: .public) s")
        onOpen()
        return true
    }

    /// Stops the timer before its end. Nothing is marked done.
    func stop() {
        guard let current = session else { return }
        release(current)
        Log.app.notice("Routine timer stopped before its end")
        onClose()
    }

    /// Looks at the clock: a timer whose end has come is over.
    func check(now: Date = Date()) {
        guard let current = session, current.isOver(at: now) else { return }
        release(current)
        onDone(current)
        let late = now.timeIntervalSince(current.end) > Self.lateSeconds
        Log.app.notice("Routine timer ended, late: \(late, privacy: .public)")
        guard !late else {
            onEndedLate(current)
            onClose()
            return
        }
        chime()
        finished = current
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shownDoneSeconds) { [weak self] in
            // Still showing that same finished timer? (Another may have been started.)
            guard let self, self.finished == current, self.session == nil else { return }
            self.dismiss()
        }
    }

    /// The "Done" screen has been seen: close the window.
    func dismiss() {
        finished = nil
        onClose()
    }

    private func release(_ current: RoutineSession) {
        session = nil
        timer?.invalidate()
        timer = nil
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        if ownsPause { resumeCamera(current.end) }
        ownsPause = false
    }
}
