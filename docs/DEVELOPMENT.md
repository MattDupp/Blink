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
| `make uninstall` | Remove every installed copy of the app; history, recordings and model are kept |
| `make dmg` | Build the installer, `build/BlinkMonitor-<version>.dmg`, and check what is inside |
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
                 (DemoCamera), the made-up data and the list of screenshots,
                 Installation (where this copy runs from, and which copy runs)
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
  eyes run through the real pipeline, which of two copies keeps running, and one rule
  about the source: no view may store the moment it was created (see the next section).

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

`make dmg` builds `build/BlinkMonitor-<version>.dmg`. The version comes from
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
`build/BlinkMonitor-<version>-with-my-model.dmg`, under another name so that it cannot be
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
4. Drop `build/BlinkMonitor-1.0.dmg` on *Attach binaries*.
5. *Save draft* to look at it first, or *Publish release*.

Or with GitHub's command-line tool (`brew install gh`, then `gh auth login`):

```bash
gh release create v1.0 build/BlinkMonitor-1.0.dmg --title "Blink Monitor 1.0" --notes "Demo build: made-up blinks, no camera, no model. Signed ad hoc, so macOS stops the first opening. The README says how to allow it."
```

Either way this creates the tag `v1.0` on GitHub at the tip of `main`, and a public page
with the image and GitHub's own archive of the source. Anyone can download both. With
`gh`, add `--draft` to look at the page before it is public.

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
