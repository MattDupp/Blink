# Development

## Requirements

- An Apple Silicon Mac, macOS 14 or later.
- Apple's Command Line Tools (`xcode-select --install`). Full Xcode works too but is not needed.
- [uv](https://docs.astral.sh/uv/) for the Python side. It installs Python 3.12 and the packages by itself.

## Commands

Run `make` to list them.

| Command | What it does |
|---|---|
| `make doctor` | Check that this Mac has what the project needs |
| `make demo` | Build and start the demo: the whole app on made-up blinks, no camera, no model |
| `make test` | Swift tests (`swift test`) and Python tests (`pytest`) |
| `make lint` / `make format` | Check / fix the Python code's style with ruff |
| `make recorder` | Build and open the recorder; sessions go to `data/raw` |
| `make train` | Train, cross-validate by session, save `models/eyenet.pt`, convert to Core ML |
| `make improve` | Label the captures recorded in Live View, train again, convert |
| `make evaluate` | Blink-level accuracy on the annotated captures |
| `make monitor` | Build the menu-bar app, install it in `~/Applications`, start it |
| `make uninstall` | Remove the installed app; history, recordings and model are kept |
| `make snapshots` | Render every screen of both apps, in every state worth looking at, to `build/screens` with made-up data; the pictures the docs show are copied to `docs/img` |
| `make icon` | Draw the app icon |
| `make clean` | Remove build products. Never touches `data/` or `models/` |

Other tools, run from `training/` with `uv run python <script>`:

| Script | What it does |
|---|---|
| `label_captures.py` | Turns new live captures (`data/live`) into labelled pictures (`data/blinks`); `--redo` to label one again |
| `annotate.py` | Lays out candidate blinks for a person to mark; writes `blinks.csv` per capture, keeping the answers already given |
| `evaluate.py --experiments` | Compares training and counting variants |
| `figures.py` | Redraws the figures of the docs from the recordings |

`python3 scripts/sync_manifests.py` removes manifest lines whose picture you deleted by hand.

## Layout

```
Sources/BlinkCore/
    Camera/      CameraCapture: the AVFoundation session, one callback per frame
    Vision/      EyeLocator (landmarks -> eye squares), EyeCropper (square -> 64x64 buffer)
    Model/       EyeClassifier: the Core ML model
    Detection/   EyeFinder and EyeReader (the stages for one frame), FrameSchedule,
                 BlinkDetector, BlinkStats
    Monitoring/  MonitorStatus (what the monitor is doing, decided in one place),
                 PauseState, PresenceTracker (time at the screen), BlinkBreak
    History/     minute records, the CSV stores, the reminder policy, Baseline (your
                 reference and the limit), Insights (rates by hour)
    Recording/   SessionWriter and CaptureWriter: the on-disk formats
    Support/     logging, PNG and CSV files, stage timings, launch options
Sources/BlinkUI/             the camera preview and its notes, shown by both apps;
                             RateReadout, the one way the rate is written
Sources/BlinkRecorder/       the recording app
Sources/BlinkMonitor/
    App/         entry point, MonitorModel (the facts), Preferences (every stored
                 choice), the pipeline, one small controller per subject, the demo
                 (DemoCamera), the made-up data and the list of screenshots
    MenuBar/     status item, panel, and the history, settings, blink-break and
                 welcome windows; Moment (the clock a window reads)
    LiveView/    the Live View window: camera, curve, counters, captures
Tests/BlinkCoreTests/        the rules: Swift Testing suites
Tests/BlinkMonitorTests/     the app itself: its model fed by hand, the demo, its source
training/
    paths.py, captures.py, sheets.py    folders, a typed capture, sheets of pictures
    data.py, model.py, learning.py      loading, the network, augment / train / predict
    detector.py                         the counting rules, as in BlinkDetector.swift
    train.py, convert.py, evaluate.py   the commands behind make train / make evaluate
    label_captures.py, annotate.py, figures.py
    tests/
```

`BlinkCore` holds everything that is not a window, so that the two apps share it and the
tests can exercise it without a camera.

## Data, and what is not in git

`data/` and `models/` are git-ignored: they are pictures of someone's eyes and a model
trained on them.

| Path | Made by | Contents |
|---|---|---|
| `data/raw/<session>/` | the recorder | `open/`, `closed/`, `manifest.csv` |
| `data/live/<capture>/` | the Live View window | `frames/`, `trace.csv`, and `blinks.csv` once annotated |
| `data/blinks/<capture>/` | `label_captures.py` | same shape as a session |
| `data/removed/` | you | pictures set aside while cleaning labels |
| `models/` | `make train` | `eyenet.pt`, `EyeNet.mlpackage`, `EyeNet.mlmodelc`, `eyenet_reference.json` |

The app's own files are in `~/Library/Application Support/BlinkMonitor/`: `history.csv`
(one line per minute) and `performance.csv` (the pipeline's cost, one line per minute).

## Tests

- **Swift** (`Tests/BlinkCoreTests`): geometry and cropping on frames painted in memory,
  the counting rules on hand-written streams of answers, history, reminders, file formats,
  pauses, time at the screen, the blink break, and the baseline, including a month of
  decline that must move neither the reference nor the limit.
  `ModelTests` compares the app's answers with Python's on real pictures and is skipped
  when there is no trained model on the machine (as in CI).
- **Python** (`training/tests`): the labelling rule, the loader, the manifest tool, and
  the Python copy of the counting rules, including a test that its numbers equal the ones
  in `BlinkDetector.swift`.

- **The app** (`Tests/BlinkMonitorTests`): the model started from a state and fed updates
  by hand (timed pause, a camera that goes silent, the blink break), the demo's made-up
  eyes run through the real pipeline, and one rule about the source: no view may store
  the moment it was created (see the next section).

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
  the model, signed ad hoc with the hardened runtime and one entitlement (the camera).
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
- Nothing personal in the repository: check `git status` before committing new files under `docs/img`.
