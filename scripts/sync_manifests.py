#!/usr/bin/env python3
"""Makes every session's manifest.csv match the pictures that are really on disk.

WHY THIS EXISTS. Looking through the pictures and deleting the bad ones (a "closed" eye
that is half open, a blurred frame) is a normal and useful part of building a dataset:
it is called cleaning the labels. But each session also has a manifest.csv with one line
per picture, and deleting a picture in Finder leaves its line behind. This tool removes
those orphan lines.

THE RULE. The pictures on disk are the truth; the manifest describes them. So:
  - a manifest line whose picture is gone       -> the line is removed
  - a picture on disk that has no manifest line -> reported, never deleted
    (the tool cannot know its label details, and it never deletes a picture)

USAGE
    python3 scripts/sync_manifests.py            # fix every session in data/raw
    python3 scripts/sync_manifests.py --check    # only report, change nothing
    python3 scripts/sync_manifests.py <folder>   # another data folder

Only the Python standard library is used: nothing to install.
"""

import argparse
import csv
import os
import sys
import tempfile
from pathlib import Path


def sync_session(session: Path, check_only: bool) -> tuple[int, int, int]:
    """Returns (lines kept, lines removed, pictures without a line) for one session."""
    manifest = session / "manifest.csv"
    with manifest.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.reader(handle))
    if not rows:
        raise ValueError("manifest.csv is empty (no header line)")

    header, lines = rows[0], rows[1:]
    file_column = header.index("file")  # the picture's path inside the session folder

    kept = [line for line in lines if (session / line[file_column]).is_file()]
    removed = len(lines) - len(kept)

    listed = {line[file_column] for line in kept}
    on_disk = {
        f"{label}/{picture.name}"
        for label in ("open", "closed")
        for picture in (session / label).glob("*.png")
    }
    unlisted = len(on_disk - listed)

    if removed and not check_only:
        # Write the new manifest beside the old one, then swap it in with one rename.
        # A rename either happens or does not: a crash can never leave half a manifest.
        descriptor, temporary = tempfile.mkstemp(dir=session, prefix="manifest.", suffix=".tmp")
        try:
            with os.fdopen(descriptor, "w", newline="", encoding="utf-8") as handle:
                writer = csv.writer(handle, lineterminator="\n")
                writer.writerow(header)
                writer.writerows(kept)
            os.replace(temporary, manifest)
        except BaseException:
            os.unlink(temporary)
            raise

    return len(kept), removed, unlisted


def main() -> int:
    default_root = Path(__file__).resolve().parent.parent / "data" / "raw"
    parser = argparse.ArgumentParser(description="Make each manifest.csv match its pictures.")
    parser.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=default_root,
        help=f"folder holding the sessions (default: {default_root})",
    )
    parser.add_argument("--check", action="store_true", help="report only, change nothing")
    arguments = parser.parse_args()

    sessions = sorted(p for p in arguments.root.iterdir() if (p / "manifest.csv").is_file())
    if not sessions:
        print(f"No session found in {arguments.root}")
        return 1

    problems = 0
    for session in sessions:
        try:
            kept, removed, unlisted = sync_session(session, arguments.check)
        except (ValueError, OSError) as error:
            print(f"{session.name}: SKIPPED - {error}")
            problems += 1
            continue
        if removed == 0:
            action = "already matches"
        elif arguments.check:
            action = f"{removed} lines have no picture (not changed: --check)"
        else:
            action = f"{removed} lines removed"
        print(f"{session.name}: {kept} pictures listed, {action}")
        if unlisted:
            print(f"  WARNING: {unlisted} pictures on disk have no manifest line (left as they are)")
            problems += 1
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
