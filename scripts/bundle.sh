#!/bin/bash
# Wraps a built program into a macOS app:   scripts/bundle.sh <Product> [resource ...]
#
#   build/<Product>.app/Contents/MacOS/<Product>      the program
#   build/<Product>.app/Contents/Info.plist           from App/<Product>-Info.plist
#   build/<Product>.app/Contents/Resources/...        the resources given, and the icon
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

swift build -c release --product "$PRODUCT"

APP="build/$PRODUCT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp "App/$PRODUCT-Info.plist" "$APP/Contents/Info.plist"
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
codesign --force --options runtime --entitlements App/Camera.entitlements --sign - "$APP" 2>/dev/null
echo "Built $APP"
