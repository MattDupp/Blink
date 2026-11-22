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
| `make uninstall` | Remove every installed copy of the app; history, recordings and model are kept |
| `make dmg` | Build the installer, `build/BlinkMonitor.dmg`, and check what is inside |
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
                 PauseState, BreakSchedule (look-away breaks), BlinkBreak,
                 ProofTest (the ten-tick test of the setup)
    History/     minute records, the CSV stores, the reminder policy, Baseline (your
                 reference and the limit), Insights (rates by hour), PublishedRates
                 (what studies report, with its sources: the only place such a
                 number is typed)
    Recording/   SessionScript (the poses, the pace, the 70% check), SessionPipeline (the
                 frames of the setup: saved, or read and counted), SessionWriter and
                 CaptureWriter: the on-disk formats; PaintedEye (a drawn eye, for the
                 demo and the tests); WholeFrames (a capture's frames as a movie),
                 CaptureReplay (those frames through the pipeline again),
                 RecordedCapture (a capture read back)
    Support/     logging, PNG and CSV files, stage timings, launch options
Sources/BlinkUI/             the camera preview and its notes, RateReadout (the one way the
                             rate is written), Speaker (the voice), the screenshot renderer
Sources/BlinkTrain/          the command-line tool behind `make compare`
Sources/BlinkReplay/         the command-line tool behind `make replay`
Sources/BlinkMonitor/
    App/         entry point, MonitorModel (the facts), ModelSource (which model is used),
                 Preferences (every stored choice), the pipeline, one small controller
                 per subject, the demo (DemoCamera), the made-up data and the list of
                 screenshots, Installation (where this copy runs from, and which
                 copy runs)
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
| `routines.csv` | one line each time a routine's reminder is shown, done, put off or left, a done is taken back, or a timer is started |
| `sessions/<session>/` | what the setup recorded, in the format of `data/raw`. Folders only their owner can read |
| `model/` | the model trained in the app: `eyenet.weights` (241 KB: eight bytes `EYENET01`, then 60,289 32-bit numbers) and `model.json` (when, from which sessions, how the check and the test went) |
| `model.new/`, `model.previous/` | a training in progress, and the model before the last training |
| `captures/` | Live View captures, when no `--capture-dir` was given |

**Which model the app uses**, in this order (`ModelSource`): one named at launch
(`--model=<EyeNet.mlmodelc>`), the one trained in the app once its test is passed or
waived, the one `make monitor` built in, none (the setup opens). A model trained in the
app therefore hides a built-in one; `make monitor` says so when both exist, and
Settings > Model deletes the app's own.

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
   capture's `blinks.csv`, as for any capture. A long look down at the keyboard comes out
   as one candidate and can hold several blinks: write one line per blink in its place,
   with the first and last frame of each. `annotate.py` keeps lines cut by hand.
3. `make replay`. For each capture it prints the blinks found, missed and false, three
   times: as the app counted while recording, replayed with the eyes searched on every
   frame, and replayed as the app runs.

How to read it:

- **The second of the three is the control.** It does the work the app did while
  recording, on the same frames, so whatever differs from the first is what storing the
  frames in a movie changed. On the three captures of 2026-11-20 the model's answer moved
  by 0.1 to 0.7% on average, and the same 76 blinks were counted.
- **The line that says whether a change counts differently is the blink-by-blink one**
  ("the same 36 blinks counted", or which frames only one run counted at). The score
  against the marks can move by a blink or two with nothing changed in what is counted:
  the marks cover only the frames where both eyes were read, so a blink counted one frame
  earlier, while one eye was still hidden by a head turn, is "missed" by that score.
- **Costs.** Each replay ends with what a search cost; searches of the whole frame and
  searches in the face's box are timed in the same run, so their ratio does not depend
  on how busy the Mac was. `PACE=1` hands the frames over at the camera's pace: a search
  then costs about twice what it costs flat out. Even so the figures are about half of
  what the app logs for itself (I have not established why), so use them to compare two
  ways, and time the app itself for the real figure: `--eye-search=whole-frame` starts it
  with the old search, on the same Mac and in the same light.

Other ways of finding the eyes are tried from the command line, every rhythm with every
way of finding the face (`0`: in the whole frame at every search):

```bash
make replay REPLAY_ARGS="--search-every=2,3 --detect-every=0,8,15"
```

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
  pauses, look-away breaks on hand-written timelines, the blink break, and the baseline, including a month of
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
  eyes run through the real pipeline, which of two copies keeps running, and one rule
  about the source: no view may store the moment it was created (see the next section).
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

The real app runs the same demo when it has **no model inside** and none was given with
`--model=`. That is the app the disk image installs (see [The installer](#the-installer)).
It keeps its made-up data in the same temporary settings and history, so nothing of it
reaches the real ones when a model arrives later. A model that is there and cannot be
loaded is still an error, said in the panel.

**The clock.** A window describes "now", and the screenshots need a fixed "now". The first
version gave every view `var now = Date()`. A view is created once, so that date was the
moment the app was launched, for as long as it ran: the last-hour chart never drew a
minute recorded after launch. A view now holds a `Moment`, which reads the clock each
time it is asked unless a screenshot froze it, and `AtPresent` redraws when the minute
changes. `SourceTests` fails if a stored `Date()` comes back.

## The installer

`make dmg` builds `build/BlinkMonitor.dmg`. The name carries no version, so the README's download link never changes. The version comes from
`CFBundleShortVersionString` in `App/BlinkMonitor-Info.plist`: change it there, and
`CFBundleVersion` with it, before a new release.

**A disk image** is one file that holds a small disk. Opening it mounts the disk, and Finder
shows its window: the app, and a shortcut to Applications. Installing is dragging one onto
the other. There is no installer program, and nothing is written anywhere else.

**What is on the disk:**

| File | What it is |
|---|---|
| `Blink Monitor.app` | The app, with no model inside |
| `Applications` | A symbolic link to `/Applications` |
| `.DS_Store` | Finder's notes on the window: its size, where each icon sits, the picture behind them |
| `.background.tiff` | That picture, at two resolutions |
| `.VolumeIcon.icns` | The disk's own icon |

**The five steps** of `scripts/dmg.sh`:

1. **Build the app** into a folder of its own, signed like every other build. It never packs
   a copy found in `build/` or in `~/Applications`, which may hold a model.
2. **Draw the background** with `scripts/make-dmg-background.swift`, as the icon is drawn.
   It is light on purpose: over a picture, Finder writes the icons' names in black, in
   dark mode too. To look at a design without building an image, add `--mock`: it draws
   stand-ins for the two icons and their names.
3. **Prepare `dmgbuild`**, the Python tool that writes the `.DS_Store`. `uv` installs it in
   `build/dmg/tools` from `scripts/dmg-requirements.txt`, which names exact versions and
   the checksums of their files. A file with another checksum is refused.
4. **Build the image.** `dmgbuild` reads `scripts/dmg-settings.py`. It makes a writable
   image, mounts it out of Finder's sight, copies everything in, and converts the result
   to a compressed read-only image.
5. **Check the image.** It is mounted again, hidden. The app must be there with a valid
   signature and the right version, the shortcut must point to `/Applications`, the
   layout files must exist, and no model may be inside.

Finder normally writes the `.DS_Store` when someone arranges a window by hand. Writing it
directly is what lets the image be built with nobody at the screen, and in CI.

**No model, ever, in the public image.** The app that the image installs has no model, so
it runs as the demo (`Options.demo`) and says how to train one. For your own second Mac
there is `make dmg WITH_MODEL=models/EyeNet.mlmodelc`. It writes
`build/BlinkMonitor-with-my-model.dmg`, under another name so that it cannot be
taken for the public one. Publishing that file publishes the model.

### What a downloaded app meets

- **Quarantine.** A browser marks what it downloads with an attribute,
  `com.apple.quarantine`. Finder copies the mark onto the app when it is dragged out of the
  image. An app built on your own Mac has no mark, which is why `make monitor` never asks.
- **Gatekeeper** looks at marked apps the first time they are opened. It wants a signature
  made with an Apple Developer ID, and Apple's scan of the app (notarization). Ours is
  signed ad hoc: a fingerprint with no name behind it. So Gatekeeper refuses, and the
  person has to allow it in System Settings. The README has the steps.
- **Translocation.** A marked app that is opened without having been moved by Finder runs
  from a hidden read-only copy. That is what happens when someone double-clicks the app
  inside the image's window. The app notices the read-only disk
  (`Installation.isOnDiskImage`), says so in its panel, and does not offer Start at Login.

To see Gatekeeper's verdict without downloading anything:

```bash
cp -R "/Volumes/Blink Monitor/Blink Monitor.app" /tmp/ && xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" "/tmp/Blink Monitor.app" && spctl --assess --type execute -v "/tmp/Blink Monitor.app"
```

It answers `rejected`. `codesign --verify --deep --strict` on the same copy says the
signature itself is valid: the app is intact, and its author is unknown to Apple.

### One installed copy

A copy dragged to `/Applications` and the copy `make monitor` puts in `~/Applications` are
the same app to macOS: one identifier. Three rules keep that from going wrong.

- **One copy runs.** A copy that starts while another runs from somewhere else quits, after
  asking the running one to open its panel. See `Installation.start`.
- **A replaced app takes over.** If the app is replaced on disk while it runs, the next
  opening starts the new build. It finds the old one still in memory, asks it to quit, and
  takes its place. Tested by moving a running copy away and putting a fresh one at the same
  place. Whether Finder lets you replace a running app at all was not tested: the README
  says to quit first.
- **One copy is installed.** `make monitor` stops if a copy from the image is in
  Applications, and says to remove it. `make uninstall` removes both kinds. `make dmg`
  deletes the app it packed, so that macOS does not file a third copy from `build/`.

### Signing

| | Ad hoc (today) | Developer ID and notarization |
|---|---|---|
| Cost | Nothing | An Apple Developer account, 99 USD a year |
| First opening of a download | Refused, then allowed by hand in System Settings | One question: "downloaded from the Internet, open?" |
| Camera permission after an update | Asked again: the fingerprint changed | Kept: the signature names the same developer |
| Who made it | Not said | The account's legal name, in the signature |

Everything is signed through one variable, `SIGN_IDENTITY`, which is `-` (ad hoc) unless
you set it. With an account, this is the whole change:

```bash
xcrun notarytool store-credentials blink-notary --apple-id <your Apple ID> --team-id <TEAMID>
```

```bash
make dmg SIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)" NOTARY_PROFILE=blink-notary
```

The first command asks for an app-specific password once and keeps it in the keychain.
The second signs the app and the image with a timestamp, sends the image to Apple, waits
for the answer, attaches it to the image, and draws the background without the Gatekeeper
lines. **This path is written and has never been run**: there is no certificate on the Mac
it was written on.

### Publishing a release

`make dmg` prints the image's SHA-256. The image is never committed (`.gitignore`). It is
attached to a GitHub release, and the README's download link points to the latest one.
Until a release exists, that link shows an empty page.

Once `main` is pushed, in a browser:

1. Open `https://github.com/MattDupp/blink-monitor/releases/new`.
2. In *Choose a tag*, type `v1.0` and pick *Create new tag on publish*. The target is `main`.
3. Give it the title `Blink Monitor 1.0` and a few words: a demo, and macOS stops the first opening.
4. Drop `build/BlinkMonitor.dmg` on *Attach binaries*.
5. *Save draft* to look at it first, or *Publish release*.

Or with GitHub's command-line tool (`brew install gh`, then `gh auth login`):

```bash
gh release create v1.0 build/BlinkMonitor.dmg --title "Blink Monitor 1.0" --notes "Demo build: made-up blinks, no camera, no model. Signed ad hoc, so macOS stops the first opening. The README says how to allow it."
```

Either way this creates the tag `v1.0` on GitHub at the tip of `main`, and a public page
with the image and GitHub's own archive of the source. Anyone can download both. With
`gh`, add `--draft` to look at the page before it is public.

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
