"""Replays the live captures through a model and counts the blinks it would have counted.

    cd training
    uv run python replay.py

WHY. "99.6% of pictures right" is not what you care about. You care about "did it count
my blink?". A capture holds every frame of 30 s of real blinking, and a cued capture
holds a known number of blinks (one per tick). So a model can be judged on the real
question without touching the camera: run it on the stored frames, apply the counting
rules, compare with the ticks.

THE TEST IS HONEST: for each capture, the model that replays it was trained WITHOUT that
capture's pictures. It has seen other blinks of yours, never these.
"""
import os

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import csv
from pathlib import Path

import numpy as np
import torch
from PIL import Image

from data import load
from train import predict, train

HERE = Path(__file__).resolve().parent
LIVE = HERE.parent / "data" / "live"


def count_blinks(times: list[float], closed: list[float | None]) -> list[int]:
    """The counting rules of BlinkDetector.swift, line for line (same numbers).
    Returns the positions of the frames at which a blink is counted."""
    closed_above, open_below, minimum_frames, maximum_seconds, maximum_gap = 0.6, 0.4, 2, 0.6, 0.5
    state, since, frames, last_seen, counted = "unknown", None, 0, None, []
    for i, (time, p) in enumerate(zip(times, closed)):
        if last_seen is not None and time - last_seen > maximum_gap:
            state = "unknown"
        if p is None:
            continue
        last_seen = time
        if state == "unknown":
            state, since, frames = ("closed", None, 1) if p > closed_above else ("open", None, 0)
        elif state == "open":
            if p > closed_above:
                state, since, frames = "closed", time, 1
        elif p >= open_below:
            frames += 1
        else:
            state = "open"
            if since is not None and time - since <= maximum_seconds and frames >= minimum_frames:
                counted.append(i)
    return counted


def read_capture(capture: Path) -> tuple[list[dict], torch.Tensor, torch.Tensor]:
    """The trace lines and the two eyes' pictures, frame by frame."""
    with (capture / "trace.csv").open(newline="", encoding="utf-8") as handle:
        rows = [r for r in csv.DictReader(handle) if r["p_left"] and r["p_right"]]

    def pictures(side: str) -> torch.Tensor:
        stack = np.stack([np.asarray(Image.open(capture / "frames" / f"f{int(r['frame']):06d}_{side}.png").convert("RGB"))
                          for r in rows])
        return torch.from_numpy(stack).permute(0, 3, 1, 2).contiguous()

    return rows, pictures("L"), pictures("R")


def per_tick(rows: list[dict], counted: list[int]) -> tuple[int, int]:
    """(ticks followed by a counted blink, number of ticks)."""
    ticks = [i for i, r in enumerate(rows) if r["tick"] == "1"]
    hit = 0
    for k, start in enumerate(ticks):
        end = ticks[k + 1] if k + 1 < len(ticks) else len(rows)
        hit += any(start <= i < end for i in counted)
    return hit, len(ticks)


def main() -> None:
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    data = load()
    images, labels = data.images.to(device), data.labels.to(device)

    print("\ncapture                   blinks counted live   replayed by a model that never saw the capture")
    for capture in sorted(p for p in LIVE.iterdir() if (p / "trace.csv").is_file()):
        rows, left, right = read_capture(capture)
        times = [float(r["time"]) for r in rows]

        # 1. The rules written here must be the app's rules: replaying the answers the
        #    app recorded has to count the very blinks the app counted.
        recorded = count_blinks(times, [float(r["p_mean"]) for r in rows])
        live = [i for i, r in enumerate(rows) if r["event"] == "blink"]
        if recorded != live:
            raise SystemExit(f"{capture.name}: the Python rules do not reproduce the app's count "
                             f"({len(recorded)} against {len(live)})")

        # 2. A model trained without this capture.
        rest = data.indices(set(data.sessions) - {capture.name}).to(device)
        model = train(images[rest], labels[rest], epochs=30, seed=7)
        mean = ((predict(model, left.to(device)) + predict(model, right.to(device))) / 2).tolist()
        replayed = count_blinks(times, mean)

        if any(r["tick"] == "1" for r in rows):
            before, ticks = per_tick(rows, live)
            after, _ = per_tick(rows, replayed)
            print(f"{capture.name}   {before:2d} of {ticks} ticks           {after:2d} of {ticks} ticks "
                  f"({len(replayed)} blinks in all)")
        else:
            print(f"{capture.name}   {len(live):2d} blinks                {len(replayed):2d} blinks")


if __name__ == "__main__":
    main()
