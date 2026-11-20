"""PROBE: how bright, how contrasted and how large are the eye pictures recorded so far?

    cd training && uv run python ../spike/probes/brightness.py

Read only. It tells what "enough light" looked like in the recordings that trained a model
that works. It cannot tell where the limit is: no dark session was ever recorded.
"""

import csv
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from harness import MAIN  # noqa: E402  (the checkout that holds data/: see harness.home)

RAW = MAIN / "data" / "raw"


def main() -> None:
    for session in sorted(p for p in RAW.iterdir() if (p / "manifest.csv").is_file()):
        means, spreads, sides = [], [], []
        with (session / "manifest.csv").open(newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                path = session / row["file"]
                if not path.is_file():
                    continue
                gray = np.asarray(Image.open(path).convert("L"), dtype=np.float32)
                means.append(gray.mean())
                spreads.append(gray.std())
                sides.append(int(row["crop_side"]))
        print(
            f"{session.name}: {len(means)} pictures; "
            f"brightness (0-255) median {np.median(means):.0f}, "
            f"darkest 5% under {np.quantile(means, 0.05):.0f}; "
            f"contrast median {np.median(spreads):.0f}, lowest 5% under {np.quantile(spreads, 0.05):.0f}; "
            f"eye square median {np.median(sides):.0f} px, smallest {min(sides)} px"
        )


if __name__ == "__main__":
    main()
