"""Prepares the live captures for a person to say, once, where the real blinks are.

    cd training
    uv run python annotate.py

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

An existing blinks.csv is never overwritten: its answers are kept and only new candidates
are added.
"""

import csv
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
LIVE = HERE.parent / "data" / "live"
SHEETS = HERE / "out" / "annotate"

SPIKE = 0.1  # a model answer above this opens a candidate
OUTLINE_DIP = 0.5  # outline height, 0 = the capture's most closed, 1 = its usual open
JOIN_FRAMES = 4  # candidates closer than this are one candidate
PAD_FRAMES = 3  # frames shown before and after
STRIP_FRAMES = 11  # frames per strip (a longer candidate is centred on its peak)
FIELDS = ["id", "first_frame", "last_frame", "kind", "note"]


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def read_trace(capture: Path) -> list[dict]:
    with (capture / "trace.csv").open(newline="", encoding="utf-8") as handle:
        return [row for row in csv.DictReader(handle) if row["p_left"] and row["p_right"]]


def candidates(rows: list[dict]) -> list[tuple[int, int]]:
    """The stretches of rows (first, last) where a blink may have happened."""
    flagged = [False] * len(rows)  # a model spike, or the outline half-way down
    strong = [False] * len(rows)  # a model spike, or the outline nearly flat
    for p_column, outline_column in (("p_left", "open_left"), ("p_right", "open_right")):
        raw = [float(row[outline_column]) for row in rows]
        low, usual = percentile(raw, 0.02), percentile(raw, 0.5)
        for i, row in enumerate(rows):
            outline = (raw[i] - low) / max(usual - low, 1e-6)
            spike = float(row[p_column]) > SPIKE
            flagged[i] = flagged[i] or spike or outline <= OUTLINE_DIP
            strong[i] = strong[i] or spike or outline <= OUTLINE_DIP / 2

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
    for first, last in stretches_of(flagged, 0, len(rows) - 1):
        if last - first + 1 <= STRIP_FRAMES:
            result.append((first, last))
        else:
            result += stretches_of(strong, first, last) or [(first, last)]
    return result


def strip(capture: Path, rows: list[dict], first: int, last: int, label: str, tile: int = 46) -> Image.Image:
    """Both eyes of one candidate, frame by frame, with the app's answer under each."""
    peak = max(range(first, last + 1), key=lambda i: float(rows[i]["p_left"]) + float(rows[i]["p_right"]))
    start = first - PAD_FRAMES
    if last + PAD_FRAMES - start + 1 > STRIP_FRAMES:
        start = peak - STRIP_FRAMES // 2
    start = max(0, min(start, len(rows) - STRIP_FRAMES))

    image = Image.new("RGB", (STRIP_FRAMES * tile, 2 * tile + 24), "white")
    draw = ImageDraw.Draw(image)
    draw.text((2, 0), label, fill="black")
    for column in range(STRIP_FRAMES):
        i = start + column
        if i >= len(rows):
            break
        row = rows[i]
        for line, side in enumerate("LR"):
            source = capture / "frames" / f"f{int(row['frame']):06d}_{side}.png"
            if source.is_file():
                picture = Image.open(source).convert("RGB").resize((tile, tile), Image.LANCZOS)
                image.paste(picture, (column * tile, 12 + line * tile))
        inside = first <= i <= last
        text = f"{float(row['p_left']) * 100:.0f} {float(row['p_right']) * 100:.0f}"
        draw.text((column * tile + 2, 12 + 2 * tile), text, fill="black" if inside else "gray")
    return image


def annotate(capture: Path) -> tuple[int, int]:
    """Writes the sheets and the blinks.csv of one capture. Returns (candidates, still unanswered)."""
    rows = read_trace(capture)
    stretches = candidates(rows)

    # Keep the answers already given: a candidate is recognised by its frames.
    answers_file = capture / "blinks.csv"
    known: dict[tuple[str, str], dict] = {}
    if answers_file.is_file():
        with answers_file.open(newline="", encoding="utf-8") as handle:
            known = {(r["first_frame"], r["last_frame"]): r for r in csv.DictReader(handle)}

    lines, strips = [], []
    for number, (first, last) in enumerate(stretches, start=1):
        key = (rows[first]["frame"], rows[last]["frame"])
        previous = known.get(key, {})
        lines.append(
            {
                "id": number,
                "first_frame": key[0],
                "last_frame": key[1],
                "kind": previous.get("kind", ""),
                "note": previous.get("note", ""),
            }
        )
        ticked = any(rows[i]["tick"] == "1" for i in range(max(0, first - 30), first + 1))
        label = f"#{number}  frames {key[0]}-{key[1]}" + ("  (after a tick)" if ticked else "")
        strips.append(strip(capture, rows, first, last, label))

    with answers_file.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(lines)

    SHEETS.mkdir(parents=True, exist_ok=True)
    for old in SHEETS.glob(f"{capture.name}_*.png"):
        old.unlink()
    per_sheet, columns = 16, 2
    for sheet_number, start in enumerate(range(0, len(strips), per_sheet), start=1):
        batch = strips[start : start + per_sheet]
        width, height = batch[0].size
        sheet = Image.new("RGB", (columns * (width + 12), -(-len(batch) // columns) * (height + 8)), "white")
        for position, image in enumerate(batch):
            sheet.paste(image, ((position % columns) * (width + 12), (position // columns) * (height + 8)))
        sheet.save(SHEETS / f"{capture.name}_{sheet_number:02d}.png")

    return len(lines), sum(1 for line in lines if not line["kind"])


def main() -> None:
    captures = sorted(p for p in LIVE.iterdir() if (p / "trace.csv").is_file()) if LIVE.is_dir() else []
    if not captures:
        raise SystemExit(f"No capture found in {LIVE}")
    for capture in captures:
        total, unanswered = annotate(capture)
        print(f"{capture.name}: {total} candidates, {unanswered} to answer in {capture / 'blinks.csv'}")
    print(f"\nStrips to look at: {SHEETS}")
    print("Under each frame: the app's answer for the left and the right eye, in %.")


if __name__ == "__main__":
    main()
