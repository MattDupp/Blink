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
    # Rule 5: how far the eyes may move up or down during a closure that is counted, in
    # distances between the eyes. A nod looks like closing eyes from the camera.
    maximum_up_down: float = 0.15


def combine(left: float, right: float) -> float:
    """The two eyes' answers as one number: `EyeFusion.combine` in Swift (the average)."""
    return (left + right) / 2


Level = tuple[float, float]  # where the eyes were: (height of the point between them, distance apart), pixels


def count_blinks(
    times: list[float],
    closed: list[float | None],
    settings: Settings = Settings(),
    levels: list[Level | None] | None = None,
) -> list[int]:
    """Returns the positions of the frames at which a blink is counted.

    `closed[i]` is the model's answer for frame i (None when no eye could be read),
    `times[i]` its time in seconds, `levels[i]` where the eyes were (`EyeLevel` in Swift;
    None, or no list at all, when not known: rule 5 then does not apply).
    """
    levels = levels if levels is not None else [None] * len(times)
    state, since, frames, last_seen, peak = "unknown", None, 0, None, 0.0
    last_level: Level | None = None
    heights: tuple[float, float, float] | None = None  # lowest, highest, distance apart

    def note(level: Level | None) -> None:
        nonlocal heights
        if level is None:
            return
        height, apart = level
        heights = (
            (height, height, apart)
            if heights is None
            else (min(heights[0], height), max(heights[1], height), heights[2])
        )

    counted: list[int] = []
    for i, (time, p, level) in enumerate(zip(times, closed, levels, strict=True)):
        if last_seen is not None and time - last_seen > settings.maximum_gap_seconds:
            state = "unknown"
        if p is None:
            continue
        last_seen = time
        before, last_level = last_level, level

        if state == "unknown":
            # Eyes already closed when first seen: the closure cannot be timed.
            state, since, frames = ("closed", None, 1) if p > settings.closed_above else ("open", None, 0)
        elif state == "open":
            if p > settings.closed_above:
                state, since, frames, peak = "closed", time, 1, p
                heights = None
                note(before)
                note(level)
        else:
            note(level)
            if p >= settings.open_below:
                frames += 1
                peak = max(peak, p)
                continue
            state = "open"
            timed = since is not None and time - since <= settings.maximum_blink_seconds
            long_enough = frames >= settings.minimum_closed_frames or peak >= settings.single_frame_sure
            up_down = (heights[1] - heights[0]) / heights[2] if heights and heights[2] > 0 else 0.0
            if timed and long_enough and up_down <= settings.maximum_up_down:
                counted.append(i)
    return counted
