# Development

## Requirements

- An Apple Silicon Mac, macOS 14 or later.
- Apple's Command Line Tools (`xcode-select --install`). Full Xcode works too but is not needed.
- [uv](https://docs.astral.sh/uv/) for the Python side. It installs Python 3.12 and the packages by itself.
  The app itself needs no Python: it records, trains and tests by itself.

## Commands

Run `make` to list them.

| Command | What it does |
|---|---|
| `make doctor` | Check that this Mac has what the project needs |
| `make demo` | Build and start the demo: the whole app on made-up blinks, no camera, nothing recorded |
| `make test` | Swift tests (`swift test`) and Python tests (`pytest`) |
| `make lint` / `make format` | Check / fix the Python code's style with ruff |
| `make monitor` | Build the menu-bar app, install it in `~/Applications`, start it. With no model it opens its setup. With `models/EyeNet.mlmodelc` present, that model is built in. With `WHOLE_FRAMES=1`, its captures also keep the whole camera picture |
| `make recorder` | The same, with the setup window open and its sessions saved in `data/raw`, for the Python route |
| `make train` | Train in Python, cross-validate by session, save `models/eyenet.pt`, convert to Core ML, and write the same weights in the app's format |
| `make improve` | Label the captures recorded in Live View, train again, convert |
| `make evaluate` | Blink-level accuracy on the annotated captures |
| `make compare` | The app's own trainer against the Python route, on the same pictures and splits (see "Measuring the app's trainer") |
| `make replay` | Run the captures that kept whole frames through the eye finding again, and count their blinks; `PACE=1` also reports the cost of each stage |
| `make uninstall` | Remove the installed app; history, recordings and model are kept |
| `make snapshots` | Render every screen, in every state worth looking at, to `build/screens` with made-up data; the pictures the docs show are copied to `docs/img` |
| `make icon` | Draw the app icon |
| `make clean` | Remove build products. Never touches `data/` or `models/` |

Other tools, run from `training/` with `uv run python <script>`:

| Script | What it does |
|---|---|
| `label_captures.py` | Turns new live captures (`data/live`) into labelled pictures (`data/blinks`); `--redo` to label one again |
| `annotate.py` | Lays out candidate blinks for a person to mark; writes `blinks.csv` per capture, keeping the answers already given; `--replay` for the captures in `data/replay` |
| `evaluate.py --experiments` | Compares training and counting variants |
| `figures.py` | Redraws the figures of the docs from the recordings |

`python3 scripts/sync_manifests.py` removes manifest lines whose picture you deleted by hand.

`DATA=<folder>` and `MODELS=<folder>` point every command at recordings and models kept
elsewhere, for instance in another checkout: `make evaluate DATA=~/other/data`. The
Makefile hands them to the Python tools and to the tests as `BLINK_DATA` and `BLINK_MODELS`.

The app's launch options are listed at the top of `Sources/BlinkMonitor/App/Entry.swift`.

## Layout

```
Sources/BlinkCore/
    Camera/      CameraCapture: the AVFoundation session, one callback per frame
    Vision/      EyeLocator (landmarks -> eye squares), EyeCropper (square -> 64x64 buffer)
    Model/       EyeClassifier (a Core ML model, from the Python route), EyeNetwork (the
                 network written in Swift, for the models trained in the app) and its
                 weights file, ModelStore (where the app's model is kept and replaced)
    Training/    the app's own trainer: TrainingSet (sessions -> pictures),
                 PictureAlteration, EyeTrainer (MPSGraph), TrainingRun (one whole training,
                 its check, and the helper process's entry)
    Detection/   EyeFinder and EyeReader (the stages for one frame), FrameSchedule,
                 BlinkDetector, BlinkStats
    Monitoring/  MonitorStatus (what the monitor is doing, decided in one place),
                 PauseState, PresenceTracker (time at the screen), BlinkBreak,
                 ProofTest (the ten-tick test of the setup)
    History/     minute records, the CSV stores, the reminder policy, Baseline (your
                 reference and the limit), Insights (rates by hour)
    Recording/   SessionScript (the poses, the pace, the 70% check), SessionPipeline (the
                 frames of the setup: saved, or read and counted), SessionWriter and
                 CaptureWriter: the on-disk formats; PaintedEye (a drawn eye, for the
                 demo and the tests); WholeFrames (a capture's frames as a movie),
                 CaptureReplay (those frames through the pipeline again)
    Support/     logging, PNG and CSV files, stage timings, launch options
Sources/BlinkUI/             the camera preview and its notes, RateReadout (the one way the
                             rate is written), Speaker (the voice), the screenshot renderer
Sources/BlinkTrain/          the command-line tool behind `make compare`
Sources/BlinkReplay/         the command-line tool behind `make replay`
Sources/BlinkMonitor/
    App/         entry point, MonitorModel (the facts), ModelSource (which model is used),
                 Preferences (every stored choice), the pipeline, one small controller
                 per subject, the demo (DemoCamera), the made-up data and the list of
                 screenshots
    Setup/       the setup: SetupModel (its steps and facts), SetupView (its pages),
                 TrainingJob (the helper process), PaintedCamera (the demo's eyes)
    MenuBar/     status item, panel, and the history, settings, blink-break and
                 welcome windows; Moment (the clock a window reads)
    LiveView/    the Live View window: camera, curve, counters, captures
Tests/BlinkCoreTests/        the rules and the trainer: Swift Testing suites
Tests/BlinkMonitorTests/     the app itself: its model fed by hand, its setup, the demo, its source
training/
    paths.py, captures.py, sheets.py    folders, a typed capture, sheets of pictures
    data.py, model.py, learning.py      loading, the network, augment / train / predict
    detector.py                         the counting rules, as in BlinkDetector.swift
    train.py, convert.py, evaluate.py   the commands behind make train / make evaluate
    compare.py                          the Python half of make compare, and its scoring
    label_captures.py, annotate.py, figures.py
    tests/
```

`BlinkCore` holds everything that is not a window, so that recording, training and
counting share it and the tests can exercise it without a camera.

## Data, and what is not in git

`data/` and `models/` are git-ignored: they are pictures of someone's eyes and a model
trained on them.

| Path | Made by | Contents |
|---|---|---|
| `data/raw/<session>/` | the setup, started by `make recorder` | `open/`, `closed/`, `manifest.csv` |
| `data/live/<capture>/` | the Live View window | `frames/`, `trace.csv`, and `blinks.csv` once annotated |
| `data/replay/<capture>/` | the Live View window, started with `WHOLE_FRAMES=1` | a capture, plus `whole-frames.mov`, `.csv` and `.json`; `replays/` once replayed |
| `data/blinks/<capture>/` | `label_captures.py` | same shape as a session |
| `data/removed/` | you | pictures set aside while cleaning labels |
| `models/` | `make train` | `eyenet.pt`, `EyeNet.mlpackage`, `EyeNet.mlmodelc`, `eyenet_reference.json`, `eyenet.weights` |

The app's own files are in `~/Library/Application Support/BlinkMonitor/`:

| Path | Contents |
|---|---|
| `history.csv` | one line per minute |
| `performance.csv` | the pipeline's cost, one line per minute |
| `sessions/<session>/` | what the setup recorded, in the format of `data/raw`. Folders only their owner can read |
| `model/` | the model trained in the app: `eyenet.weights` (241 KB: eight bytes `EYENET01`, then 60,289 32-bit numbers) and `model.json` (when, from which sessions, how the check and the test went) |
| `model.new/`, `model.previous/` | a training in progress, and the model before the last training |
| `captures/` | Live View captures, when no `--capture-dir` was given |

**Which model the app uses**, in this order (`ModelSource`): one named at launch
(`--model=<EyeNet.mlmodelc>`), the one trained in the app once its test is passed or
waived, the one `make monitor` built in, none (the setup opens). A model trained in the
app therefore hides a built-in one; `make monitor` says so when both exist, and
Settings > Your Model deletes the app's own.

A session is the same thing in both places, written by the same `SessionWriter`. A test
on each side holds the manifest's columns to one list.

## Judging a change to the eye finding

`make evaluate` judges the model: it runs stored eye pictures through a model and counts.
It cannot judge the stage before the model. Change how the eyes are found and the squares
move by a few pixels, the pictures are no longer the stored ones, and nothing recorded
says what the model would have answered. So a capture can also keep its whole frames, and
be run again from them:

1. `make monitor WHOLE_FRAMES=1`, then the capture buttons of the Live View window. Each
   capture goes to `data/replay` with the camera's whole picture of every frame, as a
   ProRes movie (each frame stored on its own, about 1 GB a minute). This is a film of a
   face: it stays in `data/`, in folders only their owner can read.
2. `cd training && uv run python annotate.py --replay`, then mark the candidates in each
   capture's `blinks.csv`, as for any capture.
3. `make replay`. For each capture it prints the blinks found, missed and false, three
   times: as the app counted while recording, replayed with the eyes searched on every
   frame, and replayed as the app runs. `PACE=1` hands the frames over at the camera's
   pace and reports what each stage costs.

The second of the three is the control. It does the work the app did while recording, on
the same frames, so whatever differs from the first is what storing the frames in a movie
changed; the tool prints that difference frame by frame. On real eye pictures pushed
through the movie format and back, the model's answer moved by 0.2% on average and the
same 20 blinks of 20 were counted at the same frames.

Captures in `data/replay` are kept apart from `data/live` on purpose: `make evaluate` and
`make improve` do not see them, so recording some changes neither the model nor the
figures of the README.

## Measuring the app's trainer

The app trains in Swift (`EyeTrainer`), the lab in Python (`learning.py`). They are only
comparable on the same work, so `training/compare.py` lays the work out once, as a list of
trainings (train on these pictures, answer on those): the cross-validation by session, the
blink count of `make evaluate` over several random starts, and what a new user has (one to
all of the recorded sessions, no frame of a real blink). `BlinkTrain` runs the list with
the app's trainer, `compare.py python` with PyTorch, and `compare.py score` prints the same
tables for both, scored by `evaluate.py`'s own functions.

```bash
make compare COMPARE_SEEDS=7,8,9
```

It is a long job on the graphics processor: 29 minutes for thirteen seeds (61 trainings
a side: 15 minutes in Swift holding up to 1.4 GB, 13 in Python holding up to 3.7 GB),
about half of that for the default three. **Run it alone**, and never several trainings
side by side: see
[Lessons](LESSONS.md), number 8, for what happened when that was not done. What it writes
goes to `training/out/compare`, which is never committed.

The trainer keeps its weights on the graphics processor between steps, and each step
empties an autorelease pool so that the previous step's arrays are freed. A change to
`EyeTrainer` is checked with one training, alone, with the program's memory watched: it
must stay flat (it did, at 1.1 GB in the comparison tool and 650 MB in the app's helper,
where the version without the pool gained 65 MB a second).

## The setup

`SetupModel` holds the setup's facts and is fed events, like `MonitorModel`: frames
through `apply`, the trainer's words through `training(_:)`. The step to open on is not
stored: it is worked out from the sessions and the model on disk (`resumeStep`), so a
window closed in the middle loses nothing that was finished.

- **The camera is borrowed.** `MonitorModel` owns the one camera. While the setup works,
  its frames go to the setup's `SessionPipeline` and nothing is counted: the poses of a
  recording are not how anyone blinks.
- **Training runs in a helper process**: the app's own program started again with
  `--train --sessions-dir=<folder> --model-out=<folder>`. It prints one line of JSON per
  step of progress. In the tests, where there is no app to start again, the same training
  runs on a queue of the test process.
- **The model takes over without a restart**: `MonitorModel.modelChanged()` loads what is
  on disk and hands it to the pipeline, which uses it from the next frame on.
- **On painted eyes**, the whole of it runs with no camera: `PaintedCamera` hands the
  pipeline two drawn eye pictures 30 times a second, and from there the pictures are
  saved, trained on and tested by the real code. The demo offers it (*See the Setup*),
  and `--demo --play-setup` goes through it with no click, writing its steps to the log.

## Tests

- **Swift** (`Tests/BlinkCoreTests`): geometry and cropping on frames painted in memory,
  the counting rules on hand-written streams of answers, history, reminders, file formats,
  pauses, time at the screen, the blink break, and the baseline, including a month of
  decline that must move neither the reference nor the limit.
  Whole frames are written to a movie and read back, and a painted capture is replayed
  with stand-ins for Vision and for the model: its one blink must be counted once.
  `ModelTests` compares the app's answers with Python's on real pictures, for the Core ML
  model and for the network written in Swift, and is skipped when there is no trained
  model on the machine (as in CI).
  `TrainingTests` holds the app's own trainer: its weights file, the network that runs
  it, the alterations, and a whole training on painted eyes, which must learn them in
  seconds and whose two forms must agree. `SessionTests` records and tests on painted
  eyes through the setup's pipeline. The tests that train need a graphics processor; they
  run one after the other and skip themselves on GitHub's virtual Macs, where MPSGraph
  was not tried.
- **Python** (`training/tests`): the labelling rule, the loader, the manifest tool, and
  the Python copy of the counting rules, including a test that its numbers equal the ones
  in `BlinkDetector.swift`. The scoring of a count against the marks is written in both
  languages too, and one example is held to one answer in both.

- **The app** (`Tests/BlinkMonitorTests`): the model started from a state and fed updates
  by hand (timed pause, a camera that goes silent, the blink break), the demo's made-up
  eyes run through the real pipeline, and one rule about the source: no view may store
  the moment it was created (see the next section).
  `SetupTests` drives the setup by hand (no face, a short session, a training that fails
  twice, a test that fails, a window closed before the test) and then runs all of it on
  painted eyes: two sessions recorded, a model trained, ten blinks counted. It takes
  under a minute.

No test needs a camera or a face.

## The demo, and the clock

**The demo** (`make demo`) is the same program built under another name and identifier,
with one key in its Info.plist. `DemoCamera` replaces the camera and the model, and only
those: its readings enter `MonitorPipeline` after the camera stage and are counted by the
real detector, statistics and history. It has its own settings, a temporary history file,
and never opens the camera.

**The clock.** A window describes "now", and the screenshots need a fixed "now". The first
version gave every view `var now = Date()`. A view is created once, so that date was the
moment the app was launched, for as long as it ran: the last-hour chart never drew a
minute recorded after launch. A view now holds a `Moment`, which reads the clock each
time it is asked unless a screenshot froze it, and `AtPresent` redraws when the minute
changes. `SourceTests` fails if a stored `Date()` comes back.

## Building without Xcode

The project builds with the Swift Package Manager alone. Two consequences:

- **App bundles are assembled by `scripts/bundle.sh`**: the program, an `Info.plist` and
  the Python route's model when there is one, signed ad hoc with the hardened runtime and
  one entitlement (the camera). The training helper is the same program, so it needs no
  signature or entitlement of its own.
  macOS ties the camera permission to that signature, so it asks again after each rebuild
  whose code changed.
- **Some macros are unavailable** with the Command Line Tools. SwiftUI's `@State` is one,
  so view state lives in `ObservableObject` classes (`PanelState`, `SettingsState`,
  `HistoryState`), which also lets the screenshots start a window in any state. Swift Testing's macros are present
  but need a compiler flag, which `make test` adds when Xcode is absent.

## Conventions

- Comments say why, and cite the measurement when there is one.
- A change to the pipeline is judged on `make evaluate` and on the stage timings, not on impressions.
- The counting rules live in `BlinkDetector.swift` and `training/detector.py`; change them together. Tests compare the numbers, and the file formats, across the two languages.
- What a window says is derived from facts (`MonitorStatus`), never stored and kept up to date by hand.
- A new screen or state gets a line in `Snapshots.swift`, and is looked at in light and dark before it ships.
- To check a window in the running app without clicking, open it at launch (`--open=history,settings`) and read the app's log: `/usr/bin/log show --last 1m --predicate 'subsystem == "local.blinkmonitor"'`. In zsh, a bare `log` is a shell builtin, not this tool.
- Made-up data lives in `SampleData.swift` and nowhere else; it never touches the user's own files.
- A copy of the app left in `build/` is known to macOS, which may start it in place of the installed one at the next login. After running one, take it off the list: `lsregister -u build/BlinkMonitor.app` (the Makefile has the tool's full path).
- One heavy job at a time: a training, the comparison, the tests that train. Never side by side.
- Nothing personal in the repository: check `git status` before committing new files under `docs/img`.
