# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Blink is a macOS menu-bar app for digital eye strain. It counts blinks through the
webcam with a small neural network trained on each user's own eyes, inside the app, and it
carries an eye-care routine around that: look-away breaks, and reminders on a schedule.

Two halves share one set of file formats. Swift is the product: the app, two command-line
tools (`BlinkTrain`, `BlinkReplay`) and two libraries (`BlinkCore`, `BlinkUI`), built with
SwiftPM. Python (`training/`, a `uv` project) is the lab: the reference trainer and the
tools that measure blink counting.

`README.md` is the user's view, `docs/DEVELOPMENT.md` the developer's, `docs/HOW-IT-WORKS.md`
explains each stage and its rules, `docs/LESSONS.md` records mistakes that shaped the
design, and `docs/BLINK-RATE.md` is the review of published blink rates the app cites.

## Commands

Everything goes through the `Makefile`; `make` alone lists the targets.

| Command | Use |
|---|---|
| `make test` | Swift tests, then Python tests. About 75 seconds; some of them train on the graphics processor. Read all three results: two lines "Test run with N tests ... passed" and the Python count. The Python tests still pass when the Swift ones did not build |
| `make lint` / `make format` | ruff on `training/` and `scripts/` (check / fix) |
| `make build` | `swift build -c release` |
| `make demo` | Build and open the app on made-up eyes: no camera, nothing recorded |
| `make demo-tour` | The demo walks through its own screens by itself, for filming (`Tour.swift`). It opens windows on this Mac: the owner runs it |
| `make snapshots` | Render every screen and state, light and dark, to `build/screens` |
| `make dmg` | Build the installer, `build/Blink.dmg`, and check what is inside |
| `make monitor` | Install the app in `~/Applications` and start it |
| `make evaluate` | Blink counting on the annotated captures (needs `data/`): judges the model and the counting rules |
| `make replay` | Whole-frame captures through the eye finding again (needs `data/replay`): judges the stage before the model, at each level of effort |
| `make compare` | The app's trainer against the Python one, on the same pictures and splits |
| `make recorder`, `make train`, `make improve` | The Python lab route: record into `data/raw`, train, convert to Core ML |

CI (`.github/workflows/ci.yml`, macOS 15) runs `swift build -c release`,
`uv sync --locked`, `make lint`, `make test`, `make dmg`.

### One test

This Mac may have only Apple's Command Line Tools, no Xcode. A bare `swift test` then
fails to find the Swift Testing macros; `make test` adds the flag. For one suite or test:

```bash
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter BaselineTests
```

```bash
cd training && uv run pytest tests/test_detector.py::test_one_blink -q
```

With Xcode installed, `swift test --filter <name>` is enough.

### What a target does to this Mac

- **`make monitor` and `make uninstall` stop every running copy by name** and replace or
  remove `~/Applications/BlinkMonitor.app`. macOS then asks for the camera again, which
  only a person can answer. The owner's own copy is usually running: do not use these to
  test something. Use `make demo`, or a copy started with `--no-camera`, and stop it by pid.
- **One heavy job at a time.** `make train`, `make improve`, `make evaluate` and
  `make compare` train on the graphics processor, for minutes. Ask before starting one,
  never run two side by side, and never beside `make test`, which trains too. A training
  loop without a memory limit once took the whole Mac down (`docs/LESSONS.md`, number 8).
- **An `.app` left in `build/` is known to macOS**, which may start it at login in place
  of the installed one. `make demo` and `make snapshots` leave one. After a run, take it
  off the list with `lsregister -u <path>` (the Makefile's `LSREGISTER` holds the tool's
  path).
- `make clean` removes `.build` and `build`, never `data/` or `models/`.

## Architecture

### The pipeline

```
camera frame -> EyeFinder (Vision landmarks -> 64x64 eye crops) -> EyeReader (model: closed?)
             -> BlinkDetector (state machine) -> BlinkStats / minute history -> reminders
```

- `Sources/BlinkCore` is everything that is not a window. The tests exercise it without a
  camera or a face.
- Recording a session and counting go through the one `EyeFinder`. That is what guarantees
  the model is asked about pictures made exactly like the ones it learned from. Do not
  give either its own cropping path.
- Finding the eyes is most of a frame's cost. `FrameSchedule` searches on every other
  frame, and `EyeLocator` looks for the face in the whole frame only twice a second,
  placing the landmarks in the last face box in between (`EyeLocator.usual`).
- The eye pictures are cut by `DirectCrop`: Core Image's own arithmetic, written out,
  because the model learned from pictures Core Image made. `EyeCropper(way: .coreImage)`
  stays as the reference and takes what cannot be cut exactly alike. A change to either
  is judged by `BlinkReplay <captures> --crops`, and tests hold the two within one level of 255.
- How often the eyes are searched is the one lever a person has: `Effort`
  (`BlinkCore/Monitoring`), three levels, each with its `FrameSchedule` and the cost and
  count it was measured with. Settings reads its sentences from those numbers
  (`EffortWords`). Standard is `FrameSchedule()` unchanged. A new lever goes into
  `Effort.schedule` with a new measurement, never into a second setting.
- The model sits behind `EyeJudging`. There are two: `EyeClassifier` runs a Core ML model
  made by the Python route, `EyeNetwork` runs weights trained in the app. `ModelSource`
  picks, in order: one named at launch, the one trained in the app, one built into the
  bundle, none (the setup opens).

### Training in the app, and the setup

- `BlinkCore/Training/EyeTrainer` trains the network in Swift on the graphics processor
  (MPSGraph). It mirrors `training/learning.py`, and `make compare` holds the two to the
  same results. Each training step empties an autorelease pool: without it, memory grows
  until the Mac fails. A change to the trainer is checked with one training, alone, with
  memory watched.
- The app trains in a helper process: its own program started again with `--train`.
- `Sources/BlinkMonitor/Setup`: `SetupModel` holds the setup's facts and is fed events.
  The step to open on is worked out from what is on disk (`resumeStep`), not stored.
  While the setup records, the camera's frames go to `SessionPipeline` and nothing is
  counted.
- The whole setup runs without a camera on drawn eyes (`PaintedCamera`): this is how the
  demo, the snapshots and `SetupTests` exercise it. `--demo --play-setup` goes through it
  with no click and writes its steps to the log.

### The menu-bar app (`Sources/BlinkMonitor`)

- `MonitorPipeline` runs on the camera's thread. `MonitorModel` is `@MainActor` and receives
  `MonitorUpdate` values through `apply(_:now:)`. With no window open, updates are sent on
  change and once a second, not per frame.
- `MonitorModel` stores facts only. What the windows say is derived from them by
  `MonitorStatus` (in `BlinkCore/Monitoring`), never stored and kept in step by hand.
- `Entry.swift`: `launch()` sets up what exists once; `launch(demo:)` builds one model with
  its menu-bar item and windows (`Running`). Entering or leaving the demo replaces that
  whole value (`switchTo`). `Installation` decides which of two copies keeps running and
  knows when the app runs from its disk image. Launch options are in the header comment.
- `Preferences` holds every stored choice. One small controller per subject.
- **One `Notifier` shows every banner**: the low-rate reminder, the look-away break, the
  routines, the summary of the day and the evening question. A new kind gives its buttons
  and its answer with `Notifier.register`; kinds are only ever added.
- **One `BannerGate` says yes or no to every banner** (`ReminderController` owns it). Quiet
  has two sources, the one chosen in the panel and the time outside `WorkingHours`, and
  the panel says which (`QuietWords`). A part that shows banners is handed `BannerTurns`
  (`ReminderController.turns`): asked, shown and counted in one call. Until it is
  connected it shows nothing (`.never`); a banner that can wait takes the `.summary` turn.
- **Look-away breaks**: `BreakPlan`, `BreakSchedule` and `BreakTally` in
  `BlinkCore/Monitoring`. The schedule has no clock and no window: it is told whether a
  face was in view at a time, and answers with events.
- **Routines** (`BlinkCore/Routines`): reminders on a schedule, of three kinds: times of
  day, a number of times a week (`RoutineWeek`), every N minutes at the screen
  (`ScreenCount`). What is due is worked out from the routine, the record and the clock
  (`RoutineDay`), never stored. `RoutinePolicy` holds the rules that keep banners few. The
  app side is `RoutineController`. A new schedule kind plugs into `RoutineDay.slots`, a
  new built-in routine into `Routine.builtIn`; do not build a second reminder mechanism
  beside it.
- **Published blink rates**: `BlinkCore/History/PublishedRates.swift` is the only place a
  number from a study is typed, each with its source.
- **The baseline** (`BlinkCore/History/Baseline.swift`): the personal reference is measured
  once and never recomputed, so a slow decline cannot move the limit. A test simulates a
  month of decline to hold this.
- **The demo** is the same binary under another identifier (`local.blinkmonitor.demo`),
  with made-up eyes behind the `FrameSource` protocol. Its readings enter `MonitorPipeline`
  after the camera stage and are counted by the real detector.
- **History** shows weeks of seven days ending on a known day (`HistoryWeek`), not Monday
  to Sunday. The app keeps the last days in memory; the earlier weeks are read from the
  file while the History window is open (`HistoryController.loadEarlierInBackground`).
- **Made-up data** lives in `SampleData.swift` only. `Snapshots.swift` lists the screens
  that `make snapshots` renders from it.

### Python (`training/`)

`train.py` and `convert.py` produce `models/EyeNet.mlmodelc`. `label_captures.py` turns
Live View captures into training pictures, `annotate.py` collects hand-marked blinks,
`evaluate.py` scores counting against them, and `compare.py` lays out the trainings both
trainers run.

`training/detector.py` is a copy of the counting rules in
`Sources/BlinkCore/Detection/BlinkDetector.swift`. Change the two together: tests compare
their numbers, and the file formats, across the two languages.

### Data on disk

- `data/` and `models/` are git-ignored and private: pictures of a person's eyes and a
  model trained on them. Never commit them or copy them into tracked paths.
  `data/replay` holds whole camera frames, a film of a face.
- The app's own files are in `~/Library/Application Support/BlinkMonitor/`: `history.csv`,
  `routines.csv`, `breaks.csv` (the break log, `CareStore`), `eye-notes.csv` (the answers
  to the evening question), the sessions the setup recorded and the model trained from them.
- **A new record is a file of its own**, never a new column: `history.csv` is read by the
  Python side. Its line type conforms to `RecordLine` and is stored in a `RecordFile`
  (BlinkCore). It gets one entry in `MonitorModel.keptRecords` (`KeptRecords.swift`), which
  gives it its row in the Privacy tab, its copy in Export and its name in "Delete
  Everything"; and a scratch copy for the demo, the screenshots and the tests
  (`CareController.scratch`).
- The installer never holds a model: `scripts/dmg.sh` checks the app before packing and
  the image afterwards.
- Pictures in `docs/img` may show 64x64 eye crops and rendered screens, never a whole face.

## Constraints that are easy to trip over

- **No Xcode.** App bundles are assembled and ad-hoc signed by `scripts/bundle.sh`.
  SwiftUI's `@State` macro is unavailable with the Command Line Tools, so view state lives
  in `ObservableObject` classes (`PanelState`, `SettingsState`, `HistoryState`).
- **A view must not store the moment it was created** (`var now = Date()`): views are made
  once, so the date freezes at launch. Views hold a `Moment` and redraw through `AtPresent`
  (`MenuBar/Moment.swift`). `SourceTests` fails if a stored `Date()` returns.
- **Rules about time are pure.** A rule that depends on the clock, the calendar or who is
  at the screen is a type in `BlinkCore` that is handed those, and is tested on timelines
  written by hand (`BreakSchedule`, `RoutineDay`, `ScreenCount`).
- **Swift 5 language mode** on purpose (`Package.swift` explains why). The camera code
  uses `@unchecked Sendable` and a `Locked` box instead of Swift 6 isolation.
- **Accuracy claims need a measurement.** The model and the counting rules are judged on
  `make evaluate`, the eye finding on `make replay`, the app's trainer on `make compare`.
  Without recordings that can measure a change, say so instead of guessing.
- **A claim about the battery is judged at the battery**, not on instructions or a share
  of a core: `scripts/whole-mac-draw.sh counting paused counting`, run by the owner, who
  changes the app's state by hand. Measured 2026-11-23: counting draws about 2 W more
  than paused, the app's processor energy is 0.05 W of it, and neither lighter code nor
  the level of effort moved it (`docs/LESSONS.md`, number 10). Never write that a change
  saves battery from a count of instructions.
- **So do claims about cost.** `BlinkReplay <captures> --cost=<stage>` reads processor
  time, instructions, energy and graphics time for a pass over stored frames
  (`docs/DEVELOPMENT.md`, "What a stage costs"). Compare two versions by their
  instructions (two passes agree within 2%): the share of a core can differ by a quarter
  between two passes of the same code.
  What the app uses with a real camera is another number, which only its owner can measure.
- **`make replay` writes into the captures' folders.** For recordings that must stay as
  they are, pass `REPLAY_ARGS="--traces=<a folder of yours>"`.
- **No medical claim.** The app reminds people of a routine they chose and reports what
  studies found. It does not advise on treatment, and its words must not start to.
  The evening note about how the eyes feel is stored and shown, never interpreted, and
  the one comparison in History (`KeptFinding`) is two of the person's own numbers with
  "they do not say why". Tests read those words and fail on "because", "better", "should".
- **What a person did not switch on does not happen.** Every banner, sound, question and
  shortcut added since the first release is a switch that starts off.
- **A text style is asked with `textStyle(.callout)`**, never `font(.callout)`, and a small
  control with `smallControl()`: "Larger text" reaches a view only through `TextScale`
  (BlinkUI). A window's fixed width is `windowWidth(_:)`. `SourceTests` holds the first
  two. Text drawn inside a chart keeps its size.
- **One name for each thing a user reads.** "Your usual rate", "limit", "lowest limit",
  "recording", "reminder", "at the screen", "blinks a minute", "Quiet", "Show in Finder".
  `SourceTests` fails when a retired word returns in a quoted string. Names in the code
  may differ (`reference`, `floor`, `session`).
- **The app is called Blink.** It was Blink Monitor until 24 November 2026, now a retired
  word. What macOS keys on keeps the old name: the bundle ids `local.blinkmonitor.*`, the
  log subsystem, the data folder `BlinkMonitor` and the executable. Renaming one of them
  resets the settings and the camera permission, or leaves the history and the model
  behind. The disk image is `Blink.dmg` and holds `Blink.app`. `make monitor` installs
  `BlinkMonitor.app`: the Makefile tells the two copies apart by their file names
  (`DRAGGED`, which also lists version 1.0's `Blink Monitor.app`).
- **A fact said in several places is one sentence.** The low rate is `LowRateWords`, for
  the panel, the banner and the tooltip. The camera's sentences are in `CameraNote`, worded
  by `CameraPlace`: a lid is named only on a portable Mac, for the Mac's own camera.
- **Numbers and times go through `Format`** (`count`, `duration`, `rate`, `hour`), never
  through a hand-made plural or `"%d:00"`. A missing number is `Format.none`, a real dash.
- **A stored choice has its default in `Preferences.Standard`**, read by the first launch
  and by "Reset to Defaults". A new choice gets a line there and one in
  `Preferences.choices`, which `init`, `resetChoices` and `hasChoices` all read. The reset
  never touches what was measured or lived: the usual rate, the history, the model, the
  routines and their log.
- **A window's main button is `.mainButton()`** (BlinkUI), not
  `.keyboardShortcut(.defaultAction)`: the pictures then draw it tinted. `SourceTests` holds it.
- **Nothing changes the screen's light while a pose is recorded.** The screen lights the
  face, and a model can learn the light instead of the eyelid. The sign at the end of a
  closed-eye pose (`PoseSignal`) starts after the recording stops and ends before the next.
- **Anything that erases asks through `Confirm`** (BlinkUI), with its words in
  `EraseWords`. `Uninstall.deleteEverything` is "Delete Everything and Quit": a test gives
  it a temporary folder and a settings store of its own. Never run it, or press the
  button, against the real folder.

## Checking the UI without clicking

- `make snapshots`, then look at the pictures in `build/screens`. A new screen or state
  gets a line in `Snapshots.swift` and is looked at in light and dark.
  The pictures have English numbers and a 24-hour clock, whatever this Mac is set to.
  `make snapshots` also copies the pictures the docs show into `docs/img`: commit those
  with the change they show, or put them back with `git checkout -- docs/img`.
  Settings is drawn whole there; in the app its tabs share one height and scroll.
- Open windows at launch: `--open=setup,live-view,history,settings,blink-break,routine-timer`
  (the demo app accepts it too).
- Read the app's log with the full path. In zsh a bare `log` is a shell builtin and
  returns nothing:

```bash
/usr/bin/log show --last 1m --predicate 'subsystem == "local.blinkmonitor"'
```

## Conventions

- The code is written to be read by someone learning. Comments say why, and cite the
  measurement and its date when there is one. Keep that style.
- Docs use plain words and short sentences. Numbers in the README are measured ones.
