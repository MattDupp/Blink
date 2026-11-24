#!/bin/bash
# Builds the installer:   scripts/dmg.sh     (or: make dmg)
#
#   build/BlinkMonitor.dmg               one file to download: opening it shows the app
#                                        next to a shortcut to Applications
#
# A DISK IMAGE (.dmg) is one file that holds a small disk. Opening it "mounts" the disk:
# it appears in Finder like a USB stick, with a window of its own. Installing is dragging
# the app out of that window into Applications; there is no installer program, and
# nothing is written anywhere else.
#
# WHAT THIS IMAGE NEVER HOLDS: a trained model. The model is made from pictures of its
# owner's eyes and stays on their Mac (see the README). The app built here has none: the
# first time it is opened, it sets itself up on its owner's eyes (ModelSource, SetupModel).
# This script checks the app before packing it, and checks the finished image again.
#
#   WITH_MODEL=<EyeNet.mlmodelc>   the only way to put a model in: an image for your own
#                                  Macs, under another file name so that it cannot be
#                                  taken for the public one
#   SIGN_IDENTITY, NOTARY_PROFILE  sign with an Apple Developer ID and have Apple notarize
#                                  the image (see "Signing" in docs/DEVELOPMENT.md)
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
WITH_MODEL="${WITH_MODEL:-}"
export SIGN_IDENTITY

VOLUME="Blink Monitor"                  # the disk's name, in Finder and in the window's title
WORK="build/dmg"                        # everything this script makes on the way
APP="$WORK/$VOLUME.app"
MOUNT="$WORK/mount"
# The version is written once, in the app's Info.plist; the file name follows it.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/BlinkMonitor-Info.plist)"
# The file's name carries no version, on purpose: the README links straight to
# releases/latest/download/BlinkMonitor.dmg, and that link then never changes. The
# version is in the app (Get Info), in the release's title and in the check of step 5.
DMG="build/BlinkMonitor.dmg"
[ -z "$WITH_MODEL" ] || DMG="build/BlinkMonitor-with-my-model.dmg"

step() { printf '\n== %s\n' "$1"; }
stop() { printf '\nNot built: %s\n' "$1" >&2; exit 1; }
# Recent versions of macOS announce that hdiutil's options will move to `diskutil image`,
# on every call. The new command does not exist on macOS 14 and 15, which this has to
# build on too: the announcement is left out, everything else hdiutil says is shown.
quietly() { "$@" 2>&1 | { grep -v "hdiutil: WARNING: .* is deprecated" || true; }; }

# Anything a model is made of. Looked for in the app before packing and in the image after.
models_in() { find "$1" \( -name '*.mlmodelc' -o -name '*.mlpackage' -o -name '*.mlmodel' -o -name '*.pt' -o -name '*.weights' \) -print -quit; }

if [ "$NOTARY_PROFILE" != "" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    stop "NOTARY_PROFILE needs SIGN_IDENTITY too: Apple only notarizes what a Developer ID signed."
fi
if [ -n "$WITH_MODEL" ]; then
    # The app looks for a folder of exactly this name among its resources (ModelSource.builtInModel).
    if [ ! -d "$WITH_MODEL" ] || [ "$(basename "$WITH_MODEL")" != "EyeNet.mlmodelc" ]; then
        stop "WITH_MODEL=$WITH_MODEL is not the compiled model (a folder named EyeNet.mlmodelc)."
    fi
fi

# --- 1. The app -------------------------------------------------------------------------
# Built here, every time, into a folder of its own: never a copy picked up from build/ or
# from ~/Applications, which may be the one `make monitor` built with a model inside.
step "1/5  Building the app"
mkdir -p "$WORK"
if [ -n "$WITH_MODEL" ]; then
    BUNDLE="$APP" scripts/bundle.sh BlinkMonitor "$WITH_MODEL"
else
    BUNDLE="$APP" scripts/bundle.sh BlinkMonitor
    found="$(models_in "$APP")"
    [ -z "$found" ] || stop "the app holds a model ($found). The public image must not."
fi

# --- 2. The picture behind the icons ----------------------------------------------------
step "2/5  Drawing the window's background"
rm -rf "$WORK/background"
if [ -n "$NOTARY_PROFILE" ]; then
    swift scripts/make-dmg-background.swift "$WORK/background" --notarized
else
    swift scripts/make-dmg-background.swift "$WORK/background"
fi

# --- 3. The tool that lays the window out -----------------------------------------------
# dmgbuild is a Python program. uv gives it a small environment of its own in build/, and
# installs exactly the files whose checksums are in scripts/dmg-requirements.txt.
step "3/5  Preparing dmgbuild"
[ -x "$WORK/tools/bin/python" ] || uv venv --quiet --python 3.12 "$WORK/tools"
uv pip install --quiet --python "$WORK/tools/bin/python" --require-hashes -r scripts/dmg-requirements.txt

# --- 4. The image -----------------------------------------------------------------------
# dmgbuild creates an empty writable image, mounts it out of Finder's sight, copies the
# app in, adds the shortcut, the disk icon, the background and the .DS_Store that places
# them, unmounts it, and converts it to a compressed read-only image.
step "4/5  Building $DMG"
rm -f "$DMG"
quietly "$WORK/tools/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D app="$APP" -D icon=App/AppIcon.icns -D background="$WORK/background/background.png" \
    "$VOLUME" "$DMG"

# With a Developer ID, the image is signed too, then sent to Apple. NOTARIZATION is Apple
# scanning the image for malware, by machine, in a few minutes; the answer is a "ticket".
# STAPLING attaches the ticket to the image, so that a Mac without a network can read it.
# A notarized image opens with one ordinary question in place of Gatekeeper's refusal.
if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    if [ -n "$NOTARY_PROFILE" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

# --- 5. Checking what was built ---------------------------------------------------------
# The image is opened the way a Mac opens it, out of Finder's sight, and looked into.
step "5/5  Checking the image"
rm -rf "$MOUNT"
mkdir -p "$MOUNT"
quietly hdiutil attach -nobrowse -noautoopen -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
detach() { hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true; }
trap detach EXIT

inside="$MOUNT/$VOLUME.app"
[ -x "$inside/Contents/MacOS/BlinkMonitor" ] || stop "the app is not in the image."
[ "$(readlink "$MOUNT/Applications")" = "/Applications" ] || stop "the shortcut to Applications is missing."
for hidden in .DS_Store .VolumeIcon.icns .background.tiff; do
    [ -s "$MOUNT/$hidden" ] || stop "$hidden is missing: the window would open without its layout."
done
# The disk only shows its icon if its "has a custom icon" flag is set: bit 0x0400 of the
# flags, which are the ninth and tenth bytes of the Finder's notes on the disk's folder.
notes="$(xattr -px com.apple.FinderInfo "$MOUNT" 2>/dev/null | tr -d ' \n')"
flags="${notes:16:4}"
(( 16#${flags:-0} & 0x0400 )) || stop "the disk's icon flag is not set."
codesign --verify --deep --strict "$inside" || stop "the app's signature did not survive the copy."
packed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$inside/Contents/Info.plist")"
[ "$packed" = "$VERSION" ] || stop "the image holds version $packed, not $VERSION."
found="$(models_in "$MOUNT")"
if [ -z "$WITH_MODEL" ] && [ -n "$found" ]; then
    stop "the image holds a model ($found)."
fi
if [ -n "$WITH_MODEL" ] && [ -z "$found" ]; then
    stop "WITH_MODEL was given and the image holds no model."
fi
if [ "$SIGN_IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
    spctl --assess --type open --context context:primary-signature "$DMG" || stop "Gatekeeper does not accept the image."
fi
detach
trap - EXIT

# The app that went into the image is not left lying in build/. macOS notices every app
# it comes across and files it under its identifier; a second copy of the app known to
# macOS is how Notification Centre loses the icon of the installed one (see `make monitor`).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
rm -rf "$APP" "$MOUNT"

size="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
printf '\nBuilt %s (%s): %s %s, a shortcut to Applications, and the window layout.\n' "$DMG" "$size" "$VOLUME" "$VERSION"
# The file's fingerprint: whoever downloads it can compare (shasum -a 256 <file>).
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
if [ -n "$WITH_MODEL" ]; then
    echo "It holds the model $WITH_MODEL: an image for your own Macs. Publishing it publishes the model."
elif [ "$SIGN_IDENTITY" = "-" ]; then
    echo "It holds no model: the app sets itself up on its owner's eyes the first time it is opened."
    echo "It is signed ad hoc: on another Mac, macOS stops the first opening (README: \"If macOS stops it\")."
else
    echo "It holds no model: the app sets itself up on its owner's eyes the first time it is opened."
fi
