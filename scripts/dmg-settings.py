"""What the installer's disk image holds, and how its window looks. Read by dmgbuild
(scripts/dmg.sh runs it); this file only describes, it does nothing by itself.

A FINDER WINDOW REMEMBERS ITS LOOK IN A HIDDEN FILE of the folder it shows, `.DS_Store`:
the window's size, where each icon sits, the picture behind them. Finder writes that file
when someone arranges a window by hand. dmgbuild writes the same file directly, from the
numbers below, so the image can be built with nobody at the screen (and in CI).

The positions are the ones scripts/make-dmg-background.swift draws around: change them
together.
"""

import os.path

# dmgbuild runs this file with one extra global, `defines`: the -D name=value pairs of
# its command line.
given = globals()["defines"]
app = given["app"]  # build/dmg/Blink Monitor.app
app_name = os.path.basename(app)

# --- What is on the disk ---------------------------------------------------------------

files = [app]
# The shortcut is a symbolic link: a small file that says "see /Applications". On whoever's
# Mac the image is opened, it points to THAT Mac's Applications folder.
symlinks = {"Applications": "/Applications"}
# The disk's own icon (on the desktop, and in the window's title bar): the app's.
icon = given["icon"]

# --- The image file --------------------------------------------------------------------

# UDZO: compressed with zlib, read-only. The oldest compressed format, which every macOS
# opens. The app is 3 MB: a newer format would save a few kilobytes.
format = "UDZO"
compression_level = 9
# HFS+ and not APFS: a background picture and a disk icon are kept reliably on it, and
# every macOS mounts it.
filesystem = "HFS+"

# --- The window ------------------------------------------------------------------------

# ((left, top), (width, height)), the title bar included: 428 leaves 400 for the content.
window_rect = ((240, 160), (600, 428))
default_view = "icon-view"
include_list_view_settings = False
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False

background = given["background"]  # background.png; dmgbuild adds background@2x.png itself
icon_size = 112
text_size = 13
# Icons stay where they are put: no grid, no sorting.
arrange_by = None
# The centre of each icon, in points from the content's top-left corner.
icon_locations = {
    app_name: (150, 180),
    "Applications": (450, 180),
}
# Not used, on purpose: `hide_extensions`. Hiding ".app" is a note Finder keeps ON the app
# itself, and a signed app must be exactly what was signed: `codesign --verify --strict`
# then refuses it ("Finder information ... not allowed"). Finder hides ".app" by default.
