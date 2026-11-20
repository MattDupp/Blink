"""Turns the live captures (data/live) into labelled training pictures (data/blinks).

    cd training
    uv run python label_captures.py

THE PROBLEM IT SOLVES. The recorder's pictures are eyes HELD open or HELD closed. A real
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
recorder's format, so they are trained on, checked and cleaned like any session.
"""

import csv
import shutil
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
LIVE = HERE.parent / "data" / "live"
BLINKS = HERE.parent / "data" / "blinks"

SURE = 0.9  # the model's answer counts as certain from here
FLAT_OUTLINE = 0.25  # outline height, 0 = this capture's most closed, 1 = its usual open
QUIET = 0.05  # "near zero"
CALM_FRAMES = 6  # 0.2 s on each side
KEEP_OPEN_EVERY = 6

HEADER = [
    "session",
    "condition",
    "phase",
    "label",
    "variant",
    "frame",
    "time",
    "side",
    "file",
    "crop_x",
    "crop_y",
    "crop_side",
    "eye_distance",
    "roll",
    "yaw",
    "frame_w",
    "frame_h",
]


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def label_capture(capture: Path, destination: Path = BLINKS) -> tuple[int, int, list[tuple[Path, str]]]:
    """Labels one capture into `destination`. Returns (closed, open, the pictures labelled
    closed BY THE OTHER EYE - the ones worth a look)."""
    with (capture / "trace.csv").open(newline="", encoding="utf-8") as handle:
        frames = [row for row in csv.DictReader(handle) if row["p_left"] and row["p_right"]]

    sides = {"L": ("p_left", "open_left"), "R": ("p_right", "open_right")}
    p = {s: [float(f[sides[s][0]]) for f in frames] for s in sides}
    # Outline height rescaled per eye and per capture: its shape differs between the
    # two eyes and with the distance to the camera, so only the relative change counts.
    outline = {}
    for s in sides:
        raw = [float(f[sides[s][1]]) for f in frames]
        low, usual = percentile(raw, 0.02), percentile(raw, 0.5)
        outline[s] = [(value - low) / max(usual - low, 1e-6) for value in raw]

    session = destination / capture.name
    shutil.rmtree(session, ignore_errors=True)
    for label in ("open", "closed"):
        (session / label).mkdir(parents=True)

    rows, by_other_eye = [], []
    counts = {"closed": 0, "open": 0}
    for i, frame in enumerate(frames):
        around = range(max(0, i - CALM_FRAMES), min(len(frames), i + CALM_FRAMES + 1))
        calm = all(
            p["L"][j] < QUIET and p["R"][j] < QUIET and outline["L"][j] > 0.5 and outline["R"][j] > 0.5
            for j in around
        )
        for side, other in (("L", "R"), ("R", "L")):
            if p[side][i] >= SURE:
                label, variant = "closed", "blink"
            elif p[other][i] >= SURE and outline[side][i] <= FLAT_OUTLINE:
                label, variant = "closed", "blink-other-eye"
            elif calm and i % KEEP_OPEN_EVERY == 0:
                label, variant = "open", "between-blinks"
            else:
                continue

            name = f"f{int(frame['frame']):06d}_{side}.png"
            source = capture / "frames" / name
            if not source.is_file():
                continue
            shutil.copyfile(source, session / label / name)
            counts[label] += 1
            if variant == "blink-other-eye":
                by_other_eye.append(
                    (session / label / name, f"{side} p {p[side][i]:.2f} other {p[other][i]:.2f}")
                )
            rows.append(
                [
                    capture.name,
                    "live capture",
                    0,
                    label,
                    variant,
                    frame["frame"],
                    frame["time"],
                    side,
                    f"{label}/{name}",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                ]
            )

    with (session / "manifest.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(HEADER)
        writer.writerows(rows)
    return counts["closed"], counts["open"], by_other_eye


def review_sheet(pictures: list[tuple[Path, str]], destination: Path) -> None:
    """Every picture labelled closed on the word of the other eye, to be looked at."""
    tile, caption, columns = 96, 14, 12
    lines = -(-len(pictures) // columns)
    sheet = Image.new("RGB", (columns * tile, max(lines, 1) * (tile + caption)), "white")
    draw = ImageDraw.Draw(sheet)
    for position, (path, text) in enumerate(pictures):
        x, y = (position % columns) * tile, (position // columns) * (tile + caption)
        sheet.paste(Image.open(path).convert("RGB").resize((tile, tile), Image.LANCZOS), (x, y))
        draw.text((x + 2, y + tile + 1), text, fill="black")
    destination.parent.mkdir(exist_ok=True)
    sheet.save(destination)


def main() -> None:
    captures = sorted(p for p in LIVE.iterdir() if (p / "trace.csv").is_file()) if LIVE.is_dir() else []
    if not captures:
        raise SystemExit(f"No capture found in {LIVE}")

    to_review = []
    for capture in captures:
        closed, opened, by_other_eye = label_capture(capture)
        to_review += by_other_eye
        print(
            f"{capture.name}: {closed} closed "
            f"({len(by_other_eye)} on the word of the other eye), {opened} open"
        )

    sheet = HERE / "out" / "review_blink_labels.png"
    review_sheet(to_review, sheet)
    print(f"\nLabelled pictures: {BLINKS}")
    print(f"To look at ({len(to_review)} pictures labelled closed by the other eye): {sheet}")


if __name__ == "__main__":
    main()
