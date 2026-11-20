"""The blink-counting rules, in Python.

The app counts blinks with `BlinkDetector` (Sources/BlinkCore/Detection/BlinkDetector.swift).
To judge a model on recorded captures without the camera, the same rules are needed here.
They are written a second time, so two things keep the copies honest:

  - tests/test_detector.py reads the numbers out of the Swift file and fails if they differ;
  - evaluate.py replays the answers the app recorded and must count the very blinks the
    app counted.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Same names and same numbers as `BlinkDetector.Settings` in Swift."""

    closed_above: float = 0.6
    open_below: float = 0.4
    minimum_closed_frames: int = 2
    # A closure seen on ONE frame only still counts when the answer was at least this sure.
    single_frame_sure: float = 0.8
    maximum_blink_seconds: float = 0.6
    maximum_gap_seconds: float = 0.5


def combine(left: float, right: float) -> float:
    """The two eyes' answers as one number: `EyeFusion.combine` in Swift (the average)."""
    return (left + right) / 2


def count_blinks(
    times: list[float], closed: list[float | None], settings: Settings = Settings()
) -> list[int]:
    """Returns the positions of the frames at which a blink is counted.

    `closed[i]` is the model's answer for frame i (None when no eye could be read),
    `times[i]` its time in seconds.
    """
    state, since, frames, last_seen, peak = "unknown", None, 0, None, 0.0
    counted: list[int] = []
    for i, (time, p) in enumerate(zip(times, closed, strict=True)):
        if last_seen is not None and time - last_seen > settings.maximum_gap_seconds:
            state = "unknown"
        if p is None:
            continue
        last_seen = time

        if state == "unknown":
            # Eyes already closed when first seen: the closure cannot be timed.
            state, since, frames = ("closed", None, 1) if p > settings.closed_above else ("open", None, 0)
        elif state == "open":
            if p > settings.closed_above:
                state, since, frames, peak = "closed", time, 1, p
        elif p >= settings.open_below:
            frames += 1
            peak = max(peak, p)
        else:
            state = "open"
            timed = since is not None and time - since <= settings.maximum_blink_seconds
            long_enough = frames >= settings.minimum_closed_frames or peak >= settings.single_frame_sure
            if timed and long_enough:
                counted.append(i)
    return counted
