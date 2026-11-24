#!/bin/bash
# Wraps a built program into a macOS app:   scripts/bundle.sh <Product> [resource ...]
#
#   build/<Product>.app/Contents/MacOS/<Product>      the program
#   build/<Product>.app/Contents/Info.plist           from App/<Product>-Info.plist
#   build/<Product>.app/Contents/Resources/...        the resources given, and the icon
#
#   DEMO=1 scripts/bundle.sh BlinkMonitor             build/BlinkMonitorDemo.app: the same
#                                                     program under another identity (below)
#   BUNDLE="build/dmg/Blink Monitor.app" scripts/...  put the app there instead (scripts/dmg.sh)
#   SIGN_IDENTITY="Developer ID Application: ..."     sign with that certificate instead of ad hoc
#
# WHY AN APP AND NOT JUST THE PROGRAM. macOS gives the camera to an APP, identified by its
# bundle (a folder ending in .app that holds the program and an Info.plist describing it).
# The Info.plist carries the sentence shown in the camera permission window; a program
# without one is ended by macOS when it opens the camera. Xcode normally builds this
# bundle; without Xcode it is a few files in the right places, which is all this does.
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT="$1"
shift

# With Apple's Command Line Tools alone, every link prints "ld: warning: search path ...
# not found" for two folders that only exist inside Xcode. They are harmless, and they are
# the first thing a newcomer would read: they are left out, everything else is shown.
swift build -c release --product "$PRODUCT" 2>&1 | { grep -v "ld: warning: search path" || true; }

NAME="$PRODUCT"
[ "${DEMO:-}" = 1 ] && NAME="${PRODUCT}Demo"
APP="${BUNDLE:-build/$NAME.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "App/$PRODUCT-Info.plist" "$APP/Contents/Info.plist"

# THE DEMO IS ANOTHER APP as far as macOS is concerned: its own name and identifier, so
# that it shares nothing with the real one - not its settings, not its entry in
# Notification Centre, not its place in the menu bar. The key BlinkMonitorDemo is what
# the program reads to know it must run on made-up eyes (see Options.demo).
if [ "${DEMO:-}" = 1 ]; then
    plist() { /usr/libexec/PlistBuddy -c "$1" "$APP/Contents/Info.plist"; }
    plist "Set :CFBundleIdentifier local.blinkmonitor.demo"
    plist "Set :CFBundleName Blink Demo"
    plist "Set :CFBundleDisplayName Blink Demo"
    plist "Add :BlinkMonitorDemo bool true"
fi
for resource in "$@"; do
    cp -R "$resource" "$APP/Contents/Resources/"
done
if [ -f App/AppIcon.icns ]; then
    cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# macOS ties the camera permission to the app's signature. A signature made here ("ad hoc",
# "-" = no developer certificate) is a fingerprint of the app's own content: the same code
# gives the same fingerprint every time and keeps its permission, changed code gives a new
# one and macOS asks for the camera again.
#
# "--options runtime" turns on the HARDENED RUNTIME. Without it, any program running under
# your account can make this app load its own code (DYLD_INSERT_LIBRARIES) and then use
# the camera permission you gave the app, with no question asked. With it, macOS refuses
# foreign code, and the app only gets what App/Camera.entitlements declares: the camera.
#
# SIGN_IDENTITY names a certificate of the keychain instead (an Apple "Developer ID
# Application"). The signature then says WHO made the app, which is what lets Apple
# notarize it, and what lets a permission survive an update. "--timestamp" asks Apple's
# server to date the signature: notarization requires it, and an ad hoc one cannot have it.
IDENTITY="${SIGN_IDENTITY:--}"
TIMESTAMP=""
[ "$IDENTITY" = "-" ] || TIMESTAMP="--timestamp"
# shellcheck disable=SC2086   # TIMESTAMP is one word or nothing, on purpose
if ! said="$(codesign --force --options runtime $TIMESTAMP --entitlements App/Camera.entitlements \
                      --sign "$IDENTITY" "$APP" 2>&1)"; then
    echo "$said"
    echo "The app could not be signed with: $IDENTITY"
    exit 1
fi
echo "Built $APP"
