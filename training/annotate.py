"""Prepares the live captures for a person to say, once, where the real blinks are.

    cd training
    uv run python annotate.py                 the captures in data/live
    uv run python annotate.py --replay        the ones that kept whole frames, in data/replay

WHY. "The model is right on 99.7% of pictures" does not say whether your blinks are
counted. To measure that, somebody has to look at the video and mark the blinks: the
GROUND TRUTH. Looking at 3,600 frames is out of the question, so this script finds every
moment where a blink MAY have happened, and lays each one out frame by frame:

    out/annotate/<capture>_01.png, _02.png ...   numbered strips, both eyes, 33 ms apart
    data/live/<capture>/blinks.csv                one line per candidate, `kind` left empty

A candidate is any moment where
  - the app's model gave either eye more than 10% "closed", or
  - the outline Apple's Vision draws around either eye flattened (a witness that does not
    depend on our model - this is what catches a blink the model missed completely).

You then open the sheets and fill the `kind` column of blinks.csv with one word:

    blink     the lids came down far enough to hide the pupil, then reopened
    partial   the lids came down part of the way only (not counted for or against)
    none      not a blink (a glance down, a squint, a false alarm)

YOUR ANSWERS ARE NEVER LOST. Run again (after a new capture, or after changing the numbers
below), an answer follows its candidate even if the candidate's frames shifted a little.
An answered line whose candidate is no longer found is kept as it is, and reported.
"""

import argparse
import csv
from pathlib import Path

import sheets
from captures import SIDES, Capture, all_captures
from paths import LIVE, OUT, REPLAY

SHEETS = OUT / "annotate"

SPIKE = 0.1  # a model answer above this opens a candidate
OUTLINE_DIP = 0.5  # outline height, 0 = the capture's most closed, 1 = its usual open
JOIN_FRAMES = 4  # candidates closer than this are one candidate
PAD_FRAMES = 3  # frames shown before and after
STRIP_FRAMES = 11  # frames per strip (a longer candidate is centred on its peak)
FIELDS = ["id", "first_frame", "last_frame", "kind", "note"]
KINDS = ("blink", "partial", "none")


def candidates(capture: Capture) -> list[tuple[int, int]]:
    """The stretches of frames (first, last positions) where a blink may have happened."""
    count = len(capture.frames)
    flagged = [False] * count  # a model spike, or the outline half-way down
    strong = [False] * count  # a model spike, or the outline nearly flat
    for side in SIDES:
        answers, outline = capture.answers(side), capture.outline(side)
        for i in range(count):
            spike = answers[i] > SPIKE
            flagged[i] = flagged[i] or spike or outline[i] <= OUTLINE_DIP
            strong[i] = strong[i] or spike or outline[i] <= OUTLINE_DIP / 2

    def stretches_of(flags: list[bool], first: int, last: int) -> list[tuple[int, int]]:
        found: list[tuple[int, int]] = []
        for i in range(first, last + 1):
            if not flags[i]:
                continue
            if found and i - found[-1][1] <= JOIN_FRAMES:
                found[-1] = (found[-1][0], i)
            else:
                found.append((i, i))
        return found

    # A stretch too long to be one blink (eyes narrowed for seconds, with blinks inside)
    # is cut again with the stricter test, so that each blink gets its own strip.
    result: list[tuple[int, int]] = []
    for first, last in stretches_of(flagged, 0, count - 1):
        if last - first + 1 <= STRIP_FRAMES:
            result.append((first, last))
        else:
            result += stretches_of(strong, first, last) or [(first, last)]
    return result


def strip(capture: Capture, first: int, last: int, title: str):
    """Both eyes of one candidate, frame by frame, with the app's answers under each."""
    frames = capture.frames
    peak = max(range(first, last + 1), key=lambda i: frames[i].left + frames[i].right)
    start = first - PAD_FRAMES
    if last + PAD_FRAMES - start + 1 > STRIP_FRAMES:
        start = peak - STRIP_FRAMES // 2
    start = max(0, min(start, len(frames) - STRIP_FRAMES))
    shown = range(start, min(start + STRIP_FRAMES, len(frames)))

    left = [sheets.Tile(capture.picture(frames[i], "L")) for i in shown]
    right = [
        sheets.Tile(
            capture.picture(frames[i], "R"),
            f"{frames[i].left * 100:.0f} {frames[i].right * 100:.0f}",
            muted=not first <= i <= last,
        )
        for i in shown
    ]
    return sheets.grid([left, right], tile=46, title=title, text_size=10)


def carry_answers(old: list[dict], new: list[tuple[int, int]]) -> tuple[list[dict], list[dict]]:
    """Gives each new candidate (first frame number, last frame number) the answer of the
    old line it overlaps. Returns (the new lines, the answered old lines left without a
    candidate) - nothing a person typed is dropped."""
    answered = [line for line in old if line["kind"]]
    used: set[int] = set()
    lines = []
    for first, last in new:
        overlapping = [
            (n, line)
            for n, line in enumerate(answered)
            if int(line["first_frame"]) <= last and first <= int(line["last_frame"])
        ]
        kinds = {line["kind"] for _, line in overlapping}
        used |= {n for n, _ in overlapping}
        if len(kinds) == 1:
            kind, note = kinds.pop(), overlapping[0][1]["note"]
        elif kinds:  # two old candidates with different answers became one: ask again
            kind, note = "", "was: " + " + ".join(sorted(kinds))
        else:
            kind, note = "", ""
        lines.append({"first_frame": first, "last_frame": last, "kind": kind, "note": note})
    orphans = [line for n, line in enumerate(answered) if n not in used]
    return lines, orphans


def annotate(capture: Capture, sheet_folder: Path = SHEETS) -> tuple[int, int, int]:
    """Writes the sheets and the blinks.csv of one capture.
    Returns (candidates, still unanswered, answered lines kept without a candidate)."""
    stretches = candidates(capture)
    frames = capture.frames

    answers_file = capture.folder / "blinks.csv"
    old: list[dict] = []
    if answers_file.is_file():
        with answers_file.open(newline="", encoding="utf-8") as handle:
            old = list(csv.DictReader(handle))

    lines, orphans = carry_answers(old, [(frames[a].number, frames[b].number) for a, b in stretches])
    for orphan in orphans:
        orphan["note"] = (orphan["note"] + " [no longer a candidate]").strip()
    everything = sorted(lines + orphans, key=lambda line: int(line["first_frame"]))
    for number, line in enumerate(everything, start=1):
        line["id"] = number

    with answers_file.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(everything)

    strips = []
    for line, (first, last) in zip(lines, stretches, strict=True):
        ticked = any(frames[i].tick for i in range(max(0, first - 30), first + 1))
        title = f"#{line['id']}  frames {line['first_frame']}-{line['last_frame']}"
        strips.append(strip(capture, first, last, title + ("  (after a tick)" if ticked else "")))

    sheet_folder.mkdir(parents=True, exist_ok=True)
    for stale in sheet_folder.glob(f"{capture.name}_*.png"):
        stale.unlink()
    per_sheet = 16
    for sheet_number, start in enumerate(range(0, len(strips), per_sheet), start=1):
        sheets.stack(strips[start : start + per_sheet], columns=2).save(
            sheet_folder / f"{capture.name}_{sheet_number:02d}.png"
        )
    return len(lines), sum(1 for line in lines if not line["kind"]), len(orphans)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Lay out the candidate blinks of the captures, to be marked."
    )
    parser.add_argument(
        "--replay",
        action="store_true",
        help="the captures that kept whole frames (data/replay) instead of data/live",
    )
    root = REPLAY if parser.parse_args().replay else LIVE
    captures = all_captures(root)
    if not captures:
        raise SystemExit(f"No capture found in {root}")
    for capture in captures:
        total, unanswered, orphans = annotate(capture)
        print(
            f"{capture.name}: {total} candidates, {unanswered} to answer in {capture.folder / 'blinks.csv'}"
        )
        if orphans:
            print(f"  {orphans} answered lines no longer match a candidate: kept, marked in their note")
    print(f"\nStrips to look at: {SHEETS}")
    print("Under each frame: the app's answer for the left and the right eye, in %.")


if __name__ == "__main__":
    main()
