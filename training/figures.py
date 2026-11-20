"""Draws the figures of the documentation from the recordings.

    cd training
    uv run python figures.py

The recordings are private and stay on the machine; the figures written to docs/img are
the only pictures of them that are published. They show 64x64 eye crops, never a face.

    poses.png           the sixteen poses of a recording session
    augmentation.png    one picture and the altered copies the model is trained on
    wrong-labels.png    blinks that were recorded as "open" - label noise
    blink-strip.png     one real blink, frame by frame, as the first model read it
"""

import csv
from pathlib import Path

import numpy as np
import torch
from PIL import Image

from captures import Capture
from learning import augment
from paths import DOCS_IMAGES, LIVE, RAW, REMOVED
from sheets import Tile, grid

STYLE = {"tile": 112, "text_size": 15}


def first_session() -> tuple[Path, list[dict]]:
    session = sorted(p for p in RAW.iterdir() if (p / "manifest.csv").is_file())[0]
    with (session / "manifest.csv").open(newline="", encoding="utf-8") as handle:
        return session, list(csv.DictReader(handle))


def poses() -> Image.Image:
    """One picture of each pose of the first session: the open row and the closed row."""
    session, lines = first_session()
    rows = []
    for label in ("open", "closed"):
        row = []
        for phase in sorted({int(line["phase"]) for line in lines if line["label"] == label}):
            of_phase = [n for n in lines if int(n["phase"]) == phase and n["side"] == "L"]
            chosen = of_phase[len(of_phase) // 2]
            row.append(Tile(session / chosen["file"], chosen["variant"], muted=True))
        rows.append(row)
    return grid(rows, row_titles=["open", "closed"], **STYLE)


def augmentation() -> Image.Image:
    """An open and a closed eye, each followed by seven altered copies."""
    session, lines = first_session()
    torch.manual_seed(4)
    rows = []
    for label, variant in (("open", "screen"), ("closed", "gentle")):
        chosen = next(
            n for n in lines if n["label"] == label and n["variant"] == variant and n["side"] == "L"
        )
        source = Image.open(session / chosen["file"]).convert("RGB")
        values = torch.from_numpy(np.asarray(source).copy()).float() / 255  # (64, 64, 3)
        batch = values.permute(2, 0, 1).unsqueeze(0).repeat(7, 1, 1, 1)
        altered = (augment(batch) * 255).round().clamp(0, 255).byte().permute(0, 2, 3, 1)
        row = [Tile(source, "as recorded", muted=True)]
        row += [Tile(Image.fromarray(copy.numpy(), "RGB"), "altered", muted=True) for copy in altered]
        rows.append(row)
    return grid(rows, row_titles=["open", "closed"], **STYLE)


def wrong_labels() -> Image.Image:
    """Pictures recorded as "open" during which the eye was blinking."""
    files = sorted(REMOVED.rglob("*.png"))[:8]
    return grid([[Tile(f, "recorded as\nopen", muted=True) for f in files]], **STYLE)


def blink_strip() -> Image.Image:
    """One fast blink of the second cued capture, frame by frame, with the answers the
    first model gave: sure for the well-lit eye, lost on the eye in the shadow."""
    capture = Capture.load(LIVE / "20261120-105956-cued")
    frames = capture.frames
    # The frame where the two eyes disagree most.
    peak = max(range(4, len(frames) - 5), key=lambda i: frames[i].right - frames[i].left)
    rows = [
        [
            Tile(capture.picture(frame, side), f"{frame.answer(side) * 100:.0f}% closed", muted=True)
            for frame in frames[peak - 3 : peak + 5]
        ]
        for side in ("L", "R")
    ]
    return grid(rows, row_titles=["shadow", "light"], **STYLE)


def main() -> None:
    DOCS_IMAGES.mkdir(parents=True, exist_ok=True)
    for name, make in (
        ("poses", poses),
        ("augmentation", augmentation),
        ("wrong-labels", wrong_labels),
        ("blink-strip", blink_strip),
    ):
        picture = make()
        picture.save(DOCS_IMAGES / f"{name}.png")
        print(f"Wrote {DOCS_IMAGES / (name + '.png')}  {picture.size}")


if __name__ == "__main__":
    main()
