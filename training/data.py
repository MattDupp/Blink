"""Loads the recorded eye pictures into memory, ready for training.

The whole dataset is a few thousand 64x64 pictures: about 50 MB as raw numbers. That fits
in memory many times over, so we load everything once into ONE big tensor instead of
reading files during training. A tensor is a grid of numbers with any number of
dimensions; ours has four:

    images[n, c, y, x]   n = which picture, c = colour channel (red, green, blue),
                         y, x = the pixel. Shape: (N, 3, 64, 64), values 0..255.
"""

import csv
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
from PIL import Image

from paths import BLINKS, RAW

# Beyond this head turn the far eye hides behind the nose (same rule and same number as
# LocatedEyes.usableEyes in the Swift code). The first session was recorded before the
# recorder applied it, so the loader applies it too.
MAX_YAW_FOR_BOTH_EYES = 0.4


@dataclass
class EyeData:
    images: torch.Tensor  # (N, 3, 64, 64) uint8
    labels: torch.Tensor  # (N,) float32: 1.0 = closed, 0.0 = open
    rows: list[dict]  # the manifest line of each picture, same order

    def __len__(self) -> int:
        return len(self.rows)

    @property
    def sessions(self) -> list[str]:
        return sorted({row["session"] for row in self.rows})

    def indices(self, sessions: set[str]) -> torch.Tensor:
        """The positions of the pictures that belong to these sessions."""
        return torch.tensor([i for i, row in enumerate(self.rows) if row["session"] in sessions])


def is_far_eye(row: dict) -> bool:
    """True for the eye hidden behind the nose when the head is turned far to one side."""
    if not row["yaw"]:
        return False
    yaw = float(row["yaw"])
    return (yaw > MAX_YAW_FOR_BOTH_EYES and row["side"] == "R") or (
        yaw < -MAX_YAW_FOR_BOTH_EYES and row["side"] == "L"
    )


def load(roots: tuple[Path, ...] = (RAW, BLINKS)) -> EyeData:
    """Loads every session of every root: the recorder's sessions (eyes held open or
    closed) and the labelled live captures (real blinks). Each is a "session": a block of
    pictures taken together, held out together when the model is tested."""
    rows, pictures = [], []
    skipped_missing = skipped_far = 0
    sessions = sorted(
        p for root in roots if root.is_dir() for p in root.iterdir() if (p / "manifest.csv").is_file()
    )
    for session in sessions:
        with (session / "manifest.csv").open(newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                path = session / row["file"]
                if not path.is_file():  # deleted by hand, manifest not synced yet
                    skipped_missing += 1
                    continue
                if is_far_eye(row):
                    skipped_far += 1
                    continue
                # The folder name is the session's identity (the column could be edited).
                row["session"] = session.name
                row["path"] = str(path)
                pictures.append(np.asarray(Image.open(path).convert("RGB")))
                rows.append(row)

    if not rows:
        raise SystemExit(f"No picture found in {', '.join(str(r) for r in roots)}")

    # Stack N pictures of shape (64, 64, 3) into (N, 64, 64, 3), then move the colour
    # axis forward to PyTorch's convention (N, 3, 64, 64).
    images = torch.from_numpy(np.stack(pictures)).permute(0, 3, 1, 2).contiguous()
    labels = torch.tensor([1.0 if row["label"] == "closed" else 0.0 for row in rows])

    print(
        f"Loaded {len(rows)} pictures from {len({r['session'] for r in rows})} sessions "
        f"({int(labels.sum())} closed, {int((1 - labels).sum())} open)"
        + (f"; left out {skipped_far} far-eye pictures" if skipped_far else "")
        + (f"; {skipped_missing} manifest lines without a picture" if skipped_missing else "")
    )
    return EyeData(images, labels, rows)
