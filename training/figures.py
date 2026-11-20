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
import os

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont

from train import augment

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data"
OUT = HERE.parent / "docs" / "img"
TILE = 112
INK, PAPER, MUTED = (30, 30, 34), (255, 255, 255), (120, 120, 128)


def font(size: int) -> ImageFont.ImageFont:
    for path in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf"):
        if Path(path).is_file():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


SMALL, BOLD = font(15), font(17)


def tile(path: Path) -> Image.Image:
    return Image.open(path).convert("RGB").resize((TILE, TILE), Image.LANCZOS)


def grid(rows: list[list[tuple[Image.Image, str]]], row_titles: list[str] | None = None) -> Image.Image:
    """Tiles with a caption under each; an optional title on the left of each row."""
    left = 96 if row_titles else 0
    gap, caption = 6, 40
    columns = max(len(row) for row in rows)
    sheet = Image.new("RGB", (left + columns * (TILE + gap) + gap, len(rows) * (TILE + caption) + gap), PAPER)
    draw = ImageDraw.Draw(sheet)
    for y, row in enumerate(rows):
        top = gap + y * (TILE + caption)
        if row_titles:
            draw.text((gap, top + TILE // 2 - 10), row_titles[y], fill=INK, font=BOLD)
        for x, (picture, text) in enumerate(row):
            position = left + gap + x * (TILE + gap)
            sheet.paste(picture, (position, top))
            draw.multiline_text((position + 1, top + TILE + 3), text, fill=MUTED, font=SMALL, spacing=1)
    return sheet


def manifest(session: Path) -> list[dict]:
    with (session / "manifest.csv").open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def poses() -> Image.Image:
    """One picture of each pose of the first session: the open row and the closed row."""
    session = sorted(p for p in (DATA / "raw").iterdir() if (p / "manifest.csv").is_file())[0]
    lines = manifest(session)
    rows = []
    for label in ("open", "closed"):
        row = []
        for phase in sorted({int(line["phase"]) for line in lines if line["label"] == label}):
            of_phase = [n for n in lines if int(n["phase"]) == phase and n["side"] == "L"]
            chosen = of_phase[len(of_phase) // 2]
            row.append((tile(session / chosen["file"]), chosen["variant"]))
        rows.append(row)
    return grid(rows, ["open", "closed"])


def augmentation() -> Image.Image:
    """An open and a closed eye, each followed by seven altered copies."""
    session = sorted(p for p in (DATA / "raw").iterdir() if (p / "manifest.csv").is_file())[0]
    lines = manifest(session)
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
        row = [(source.resize((TILE, TILE), Image.LANCZOS), "as recorded")]
        for copy in altered:
            picture = Image.fromarray(copy.numpy(), "RGB").resize((TILE, TILE), Image.LANCZOS)
            row.append((picture, "altered"))
        rows.append(row)
    return grid(rows, ["open", "closed"])


def wrong_labels() -> Image.Image:
    """Pictures recorded as "open" during which the eye was blinking."""
    files = sorted((DATA / "removed").rglob("*.png"))[:8]
    return grid([[(tile(f), "recorded as\nopen") for f in files]])


def blink_strip() -> Image.Image:
    """One fast blink of the second cued capture, frame by frame, with the answers the
    first model gave: sure for the well-lit eye, lost on the eye in the shadow."""
    capture = DATA / "live" / "20261120-105956-cued"
    with (capture / "trace.csv").open(newline="", encoding="utf-8") as handle:
        rows = [r for r in csv.DictReader(handle) if r["p_left"] and r["p_right"]]
    # The frame where the two eyes disagree most.
    peak = max(range(4, len(rows) - 5), key=lambda i: float(rows[i]["p_right"]) - float(rows[i]["p_left"]))
    shown = rows[peak - 3 : peak + 5]
    lines = []
    for side, column in (("L", "p_left"), ("R", "p_right")):
        line = []
        for r in shown:
            answer = float(r[column]) * 100
            line.append(
                (tile(capture / "frames" / f"f{int(r['frame']):06d}_{side}.png"), f"{answer:.0f}% closed")
            )
        lines.append(line)
    return grid(lines, ["shadow", "light"])


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, make in (
        ("poses", poses),
        ("augmentation", augmentation),
        ("wrong-labels", wrong_labels),
        ("blink-strip", blink_strip),
    ):
        picture = make()
        picture.save(OUT / f"{name}.png")
        print(f"Wrote {OUT / (name + '.png')}  {picture.size}")


if __name__ == "__main__":
    main()
