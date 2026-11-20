#!/bin/bash
# Builds the recorder, wraps it into a macOS app and opens it.
#
# WHY AN APP AND NOT JUST THE PROGRAM. macOS gives the camera to an APP, identified by its
# bundle (a folder ending in .app that holds the program and an Info.plist describing it).
# The Info.plist carries the sentence shown in the camera permission window; a program
# without one is ended by macOS when it opens the camera. Xcode normally builds this
# bundle; without Xcode it is three files in the right places, which is all this does.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product BlinkRecorder

APP="build/BlinkRecorder.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/BlinkRecorder "$APP/Contents/MacOS/BlinkRecorder"
cp App/Recorder-Info.plist "$APP/Contents/Info.plist"

# macOS ties the camera permission to the app's signature. A signature made here ("ad hoc",
# "-" = no developer certificate) is a fingerprint of the app's own content: the same code
# gives the same fingerprint every time and keeps its permission, changed code gives a new
# one and macOS asks for the camera again.
codesign --force --sign - "$APP" 2>/dev/null

mkdir -p data/raw

# "scripts/run-recorder.sh --build-only" stops here: the app is built, not opened.
if [ "${1:-}" = "--build-only" ]; then
    echo "Built $APP"
    exit 0
fi

open -n "$APP" --args "--out=$PWD/data/raw"
