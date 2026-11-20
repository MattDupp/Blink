"""A live capture, read once into typed values.

A capture is what the app's Live View window records: every frame's two eye pictures
and one line per frame in trace.csv (see `CaptureWriter` in the Swift code). Four tools
work on captures. Each used to read the CSV its own way and carry the lines around as
dictionaries of text, converting "0.9731" to a number again wherever it was needed.
Here a capture is read once, into numbers, and everything asked of it has one answer.
"""

import csv
from dataclasses import dataclass
from functools import cached_property
from pathlib import Path

from paths import LIVE

# The columns CaptureWriter.swift writes (a test checks the two lists are the same).
TRACE_HEADER = "frame,time,p_left,p_right,p_mean,open_left,open_right,state,event,tick"
SIDES = ("L", "R")


@dataclass(frozen=True)
class Frame:
    """One frame in which both eyes were read."""

    number: int  # the app's frame number: it names the picture files
    time: float  # seconds, on the camera's clock
    left: float  # the model's answer for the eye on the left of the picture, as recorded
    right: float
    mean: float  # what the app's blink detector was given
    outline_left: float  # height / width of Vision's eye outline: about 0.25 open, less when closed
    outline_right: float
    counted: bool  # the app counted a blink at this frame
    tick: bool  # a cue sound was played just before this frame

    def answer(self, side: str) -> float:
        return self.left if side == "L" else self.right


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


@dataclass
class Capture:
    folder: Path
    frames: list[Frame]

    @classmethod
    def load(cls, folder: Path) -> "Capture":
        with (folder / "trace.csv").open(newline="", encoding="utf-8") as handle:
            frames = [
                Frame(
                    number=int(row["frame"]),
                    time=float(row["time"]),
                    left=float(row["p_left"]),
                    right=float(row["p_right"]),
                    mean=float(row["p_mean"]),
                    outline_left=float(row["open_left"]),
                    outline_right=float(row["open_right"]),
                    counted=row["event"] == "blink",
                    tick=row["tick"] == "1",
                )
                for row in csv.DictReader(handle)
                if row["p_left"] and row["p_right"]  # a frame with one eye unread is left out
            ]
        return cls(folder, frames)

    @property
    def name(self) -> str:
        return self.folder.name

    @property
    def times(self) -> list[float]:
        return [frame.time for frame in self.frames]

    @property
    def seconds(self) -> float:
        return self.frames[-1].time - self.frames[0].time

    @property
    def is_cued(self) -> bool:
        return any(frame.tick for frame in self.frames)

    def answers(self, side: str) -> list[float]:
        return [frame.answer(side) for frame in self.frames]

    def picture(self, frame: Frame, side: str) -> Path:
        return self.folder / "frames" / f"f{frame.number:06d}_{side}.png"

    @cached_property
    def _outlines(self) -> dict[str, list[float]]:
        """Each eye's outline height rescaled to this capture: 0 = its most closed,
        1 = its usual open. The raw height differs between the two eyes and with the
        distance to the camera, so only the relative change means anything."""
        rescaled = {}
        for side in SIDES:
            raw = [f.outline_left if side == "L" else f.outline_right for f in self.frames]
            low, usual = percentile(raw, 0.02), percentile(raw, 0.5)
            rescaled[side] = [(value - low) / max(usual - low, 1e-6) for value in raw]
        return rescaled

    def outline(self, side: str) -> list[float]:
        return self._outlines[side]

    def index_of_frame(self, number: int) -> int:
        """The position, in `frames`, of the frame with this number."""
        return self._positions[number]

    @cached_property
    def _positions(self) -> dict[int, int]:
        return {frame.number: i for i, frame in enumerate(self.frames)}


def all_captures(root: Path = LIVE) -> list[Capture]:
    folders = sorted(p for p in root.iterdir() if (p / "trace.csv").is_file()) if root.is_dir() else []
    return [Capture.load(folder) for folder in folders]
