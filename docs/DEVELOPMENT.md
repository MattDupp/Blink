# Development

## Requirements

- An Apple Silicon Mac, macOS 14 or later.
- Apple's Command Line Tools (`xcode-select --install`). Full Xcode works too but is not needed.
- [uv](https://docs.astral.sh/uv/) for the Python side. It installs Python 3.12 and the packages by itself.

## Commands

Run `make` to list them.

| Command | What it does |
|---|---|
| `make test` | Swift tests (`swift test`) and Python tests (`pytest`) |
| `make lint` / `make format` | Check / fix the Python code's style with ruff |
| `make recorder` | Build and open the recorder; sessions go to `data/raw` |
| `make train` | Train, cross-validate by session, save `models/eyenet.pt`, convert to Core ML |
| `make evaluate` | Blink-level accuracy on the annotated captures |
| `make monitor` | Build the menu-bar app, install it in `~/Applications`, start it |
| `make snapshots` | Render every screen to `docs/img` with made-up data |
| `make icon` | Draw the app icon |
| `make clean` | Remove build products. Never touches `data/` or `models/` |

Other tools, run from `training/` with `uv run python <script>`:

| Script | What it does |
|---|---|
| `label_captures.py` | Turns live captures (`data/live`) into labelled pictures (`data/blinks`) |
| `annotate.py` | Lays out candidate blinks for a person to mark; writes `blinks.csv` per capture |
| `evaluate.py --experiments` | Compares training and counting variants |
| `figures.py` | Redraws the figures of the docs from the recordings |

`python3 scripts/sync_manifests.py` removes manifest lines whose picture you deleted by hand.

## Layout

```
Sources/BlinkCore/
    Camera/      CameraCapture: the AVFoundation session, one callback per frame
    Vision/      EyeLocator (landmarks -> eye squares), EyeCropper (square -> 64x64 buffer)
    Model/       EyeClassifier: the Core ML model
    Detection/   EyeReader (the three stages for one frame), BlinkDetector, BlinkStats
    History/     minute records, the CSV store, the reminder policy
    Recording/   SessionWriter and CaptureWriter: the on-disk formats
    Support/     logging, PNG files, stage timings
Sources/BlinkUI/             the camera preview both apps show
Sources/BlinkRecorder/       the recording app
Sources/BlinkMonitor/
    App/         entry point, MonitorModel (live state), the pipeline, the small controllers
    MenuBar/     status item, panel, history and welcome windows
    Diagnostics/ the diagnostics window
Tests/BlinkCoreTests/        Swift Testing suites
training/                    PyTorch, Core ML conversion, data tools, tests/
```

`BlinkCore` holds everything that is not a window, so that the two apps share it and the
tests can exercise it without a camera.

## Data, and what is not in git

`data/` and `models/` are git-ignored: they are pictures of someone's eyes and a model
trained on them.

| Path | Made by | Contents |
|---|---|---|
| `data/raw/<session>/` | the recorder | `open/`, `closed/`, `manifest.csv` |
| `data/live/<capture>/` | the diagnostics window | `frames/`, `trace.csv`, and `blinks.csv` once annotated |
| `data/blinks/<capture>/` | `label_captures.py` | same shape as a session |
| `data/removed/` | you | pictures set aside while cleaning labels |
| `models/` | `make train` | `eyenet.pt`, `EyeNet.mlpackage`, `EyeNet.mlmodelc`, `eyenet_reference.json` |

The app's own files are in `~/Library/Application Support/BlinkMonitor/`: `history.csv`
(one line per minute) and `performance.csv` (the pipeline's cost, one line per minute).

## Tests

- **Swift** (`Tests/BlinkCoreTests`): geometry and cropping on frames painted in memory,
  the counting rules on hand-written streams of answers, history, reminders, file formats.
  `ModelTests` compares the app's answers with Python's on real pictures and is skipped
  when there is no trained model on the machine (as in CI).
- **Python** (`training/tests`): the labelling rule, the loader, the manifest tool, and
  the Python copy of the counting rules, including a test that its numbers equal the ones
  in `BlinkDetector.swift`.

No test needs a camera or a face.

## Building without Xcode

The project builds with the Swift Package Manager alone. Two consequences:

- **App bundles are assembled by `scripts/bundle.sh`**: the program, an `Info.plist` and
  the model, signed ad hoc. macOS ties the camera permission to that signature, so it asks
  again after each rebuild whose code changed.
- **Some macros are unavailable** with the Command Line Tools. SwiftUI's `@State` is one,
  so view state lives in `ObservableObject` classes. Swift Testing's macros are present
  but need a compiler flag, which `make test` adds when Xcode is absent.

## Conventions

- Comments say why, and cite the measurement when there is one.
- A change to the pipeline is judged on `make evaluate` and on the stage timings, not on impressions.
- The counting rules live in `BlinkDetector.swift` and `training/detector.py`; change them together.
- Nothing personal in the repository: check `git status` before committing new files under `docs/img`.
