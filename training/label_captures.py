"""Turns the live captures (data/live) into labelled training pictures (data/blinks).

    cd training
    uv run python label_captures.py            label the captures that are not labelled yet
    uv run python label_captures.py --redo     label every capture again

THE PROBLEM IT SOLVES. A recorded session's pictures are eyes HELD open or HELD closed. A real
blink is caught half-way and blurred, and on the darker side of the face the model
answered "open" on eyes that were plainly closed (first live test, 2026-11-20: the
image-right eye said 100% closed, the image-left eye 6% - same frame, same blink).
The model has to be shown real blink frames with the right label. But a capture is
thousands of unlabelled frames: who labels them?

THE IDEA: LET ONE EYE LABEL THE OTHER. Both eyes blink together. So when the model is
sure that one eye is closed, the other eye IS closed in that same frame - even if the
model does not see it yet. That gives a correct label exactly where the model is wrong,
which is the most valuable kind of training picture. ("Pseudo-labelling": labels produced
by a rule instead of a person.) A second, independent witness guards against mistakes:
the height of the eye outline drawn by Apple's Vision, which has nothing to do with our
model, must also say that the lid is down.

THE RULES, per eye and per frame:
  closed  - the model is sure for this eye (>= 90%), or it is sure for the OTHER eye
            and this eye's outline is nearly flat
  open    - nothing happens for 0.2 s around: both answers near zero, both outlines tall
            (one frame in six is kept: neighbouring frames are near copies)
  nothing - everything else, in particular the half-way frames, where even a person
            would hesitate. A wrong label teaches more harm than a missing one.

The pictures are COPIED to data/blinks/<capture>/open|closed with a manifest.csv, in the
format of a recorded session, so they are trained on, checked and cleaned like one.

A CAPTURE ALREADY LABELLED IS LEFT ALONE. You may have cleaned its pictures by hand;
labelling it again would bring every removed picture back. `--redo` says you mean it.
"""

import argparse
import csv
import shutil
from pathlib import Path

import sheets
from captures import SIDES, Capture, all_captures
from paths import BLINKS, OUT

SURE = 0.9  # the model's answer counts as certain from here
FLAT_OUTLINE = 0.25  # outline height, 0 = this capture's most closed, 1 = its usual open
QUIET = 0.05  # "near zero"
CALM_FRAMES = 6  # 0.2 s on each side
KEEP_OPEN_EVERY = 6

# The columns of a session's manifest.csv, as SessionWriter.swift writes them
# (a test checks the two lists are the same).
HEADER = [
    "session", "condition", "phase", "label", "variant", "frame", "time", "side", "file",
    "crop_x", "crop_y", "crop_side", "eye_distance", "roll", "yaw", "frame_w", "frame_h",
]  # fmt: skip


def label_of(capture: Capture, index: int, side: str) -> tuple[str, str] | None:
    """(label, variant) for one eye of one frame, or None when the rules stay silent."""
    other = "R" if side == "L" else "L"
    frame = capture.frames[index]
    if frame.answer(side) >= SURE:
        return "closed", "blink"
    if frame.answer(other) >= SURE and capture.outline(side)[index] <= FLAT_OUTLINE:
        return "closed", "blink-other-eye"

    around = range(max(0, index - CALM_FRAMES), min(len(capture.frames), index + CALM_FRAMES + 1))
    calm = all(
        capture.frames[j].left < QUIET
        and capture.frames[j].right < QUIET
        and capture.outline("L")[j] > 0.5
        and capture.outline("R")[j] > 0.5
        for j in around
    )
    return ("open", "between-blinks") if calm and index % KEEP_OPEN_EVERY == 0 else None


def label_capture(capture: Capture, destination: Path = BLINKS) -> tuple[int, int, list[sheets.Tile]]:
    """Labels one capture into `destination`, replacing what was there. Returns (closed,
    open, the pictures labelled closed BY THE OTHER EYE - the ones worth a look)."""
    session = destination / capture.name
    shutil.rmtree(session, ignore_errors=True)
    for label in ("open", "closed"):
        (session / label).mkdir(parents=True)

    rows, by_other_eye = [], []
    counts = {"closed": 0, "open": 0}
    for index, frame in enumerate(capture.frames):
        for side in SIDES:
            decided = label_of(capture, index, side)
            source = capture.picture(frame, side)
            if decided is None or not source.is_file():
                continue
            label, variant = decided
            copy = session / label / source.name
            shutil.copyfile(source, copy)
            counts[label] += 1
            if variant == "blink-other-eye":
                other = "R" if side == "L" else "L"
                by_other_eye.append(
                    sheets.Tile(copy, f"{side} {frame.answer(side):.2f} other {frame.answer(other):.2f}")
                )
            line = dict.fromkeys(HEADER, "")
            line |= {
                "session": capture.name,
                "condition": "live capture",
                "phase": 0,
                "label": label,
                "variant": variant,
                "frame": frame.number,
                "time": f"{frame.time:.4f}",
                "side": side,
                "file": f"{label}/{source.name}",
            }
            rows.append(line)

    with (session / "manifest.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    return counts["closed"], counts["open"], by_other_eye


def main() -> None:
    parser = argparse.ArgumentParser(description="Label the real blink frames of the live captures.")
    parser.add_argument(
        "--redo",
        action="store_true",
        help="label again the captures already labelled (pictures you removed by hand come back)",
    )
    arguments = parser.parse_args()

    captures = all_captures()
    if not captures:
        raise SystemExit(
            "No capture found in data/live. Record one in the app: Live View > Record Freely (60 s), "
            "with the app started by 'make monitor'."
        )

    to_review: list[sheets.Tile] = []
    for capture in captures:
        if (BLINKS / capture.name).is_dir() and not arguments.redo:
            print(f"{capture.name}: already labelled, left as it is (--redo to label it again)")
            continue
        closed, opened, by_other_eye = label_capture(capture)
        to_review += by_other_eye
        print(
            f"{capture.name}: {closed} closed "
            f"({len(by_other_eye)} on the word of the other eye), {opened} open"
        )

    print(f"\nLabelled pictures: {BLINKS}")
    if to_review:
        OUT.mkdir(exist_ok=True)
        sheet = OUT / "review_blink_labels.png"
        sheets.flow(to_review, columns=12).save(sheet)
        print(f"To look at ({len(to_review)} pictures labelled closed by the other eye): {sheet}")


if __name__ == "__main__":
    main()
