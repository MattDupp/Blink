#!/bin/bash
# Checks that this Mac has what the project needs:   scripts/doctor.sh [swift] [uv]
#
# With no argument (make doctor) it checks everything and says so line by line. With
# arguments it checks only those, and stays silent unless one is missing: the Makefile
# calls it that way before each step, so that a missing tool is said in one plain
# sentence at the start, not as an error in the middle of a build.
set -uo pipefail

wanted=("$@")
quiet=1
if [ ${#wanted[@]} -eq 0 ]; then
    wanted=(mac swift uv)
    quiet=0
fi

missing=0
ok()  { [ "$quiet" -eq 1 ] || printf '  ok       %s\n' "$1"; }
bad() { printf '  MISSING  %s\n           %s\n' "$1" "$2"; missing=1; }

for item in "${wanted[@]}"; do
    case "$item" in
    mac)
        if [ "$(uname -m)" = "arm64" ]; then
            ok "Apple Silicon Mac"
        else
            bad "an Apple Silicon Mac (this one is $(uname -m))" "The model is trained and run with Apple's own chips; an Intel Mac is not supported."
        fi
        version="$(sw_vers -productVersion)"
        if [ "${version%%.*}" -ge 14 ]; then
            ok "macOS $version"
        else
            bad "macOS 14 or later (this is $version)" "Update macOS in System Settings > General > Software Update."
        fi
        ;;
    swift)
        if xcrun --find swift >/dev/null 2>&1; then
            ok "Swift ($(swift --version 2>/dev/null | head -1 | sed 's/.*Swift version \([0-9.]*\).*/\1/'))"
        else
            bad "Apple's Command Line Tools (the Swift compiler)" "Install them with:  xcode-select --install   (full Xcode is not needed)"
        fi
        ;;
    uv)
        if command -v uv >/dev/null 2>&1; then
            ok "uv ($(uv --version 2>/dev/null | awk '{print $2}'))"
        else
            bad "uv (it installs Python and the training packages)" "Install it with:  curl -LsSf https://astral.sh/uv/install.sh | sh   then open a new terminal."
        fi
        ;;
    esac
done

if [ "$missing" -eq 1 ]; then
    [ "$quiet" -eq 1 ] && echo "Run 'make doctor' to check everything this project needs."
    exit 1
fi
[ "$quiet" -eq 1 ] || echo "Everything is there. Start with:  make demo   (or make monitor, to use it on your own eyes)"
