#!/bin/bash
# Builds Blink Monitor, the menu-bar app, with the trained model inside; installs it in
# your Applications folder and starts it. (See run-recorder.sh for why it must be an app.)
#
#   scripts/run-monitor.sh               build, install, start
#   scripts/run-monitor.sh --live        the same, and open the live view at once
#   scripts/run-monitor.sh --build-only  build into build/ only: nothing installed or started
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="models/EyeNet.mlmodelc"
if [ ! -d "$MODEL" ]; then
    echo "The model is missing: $MODEL"
    echo "Make it with:  cd training && uv run python train.py && uv run python convert.py"
    exit 1
fi

swift build -c release --product BlinkMonitor

APP="build/BlinkMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BlinkMonitor "$APP/Contents/MacOS/BlinkMonitor"
cp App/Monitor-Info.plist "$APP/Contents/Info.plist"
# The model travels inside the app: Contents/Resources is where an app keeps its data files.
cp -R "$MODEL" "$APP/Contents/Resources/EyeNet.mlmodelc"
codesign --force --sign - "$APP" 2>/dev/null

if [ "${1:-}" = "--build-only" ]; then
    echo "Built $APP"
    exit 0
fi

# An app that starts at login must live somewhere that does not move or get rebuilt:
# ~/Applications is the per-user Applications folder (no administrator password needed).
INSTALLED="$HOME/Applications/BlinkMonitor.app"

# Stop the copy that is running, if any, and wait for it to be gone.
if pkill -x BlinkMonitor 2>/dev/null; then
    while pgrep -x BlinkMonitor >/dev/null; do sleep 0.2; done
fi

mkdir -p "$HOME/Applications" data/live
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"
echo "Installed $INSTALLED"

if [ "${1:-}" = "--live" ]; then
    open "$INSTALLED" --args "--capture-dir=$PWD/data/live" --live
else
    open "$INSTALLED" --args "--capture-dir=$PWD/data/live"
fi
echo "Blink Monitor is running: look for the eye in the menu bar, top right of the screen."
