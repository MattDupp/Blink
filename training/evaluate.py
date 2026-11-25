"""Measures what matters: are real blinks counted?

    cd training
    uv run python evaluate.py                 the current rules, on every capture
    uv run python evaluate.py --experiments   compares ways of training and of counting

"99.7% of pictures right" is not the question. The question is "did it count my blink?".
A capture holds every frame of real blinking, and annotate.py + a person's eyes gave each
capture its ground truth (data/live/<capture>/blinks.csv). So a model can be judged on
the real question without the camera: run it on the stored frames, apply the counting
rules, compare with the truth.

THE TEST IS HONEST. For each capture, the model that judges it was trained WITHOUT that
capture's pictures: it has seen other blinks of yours, never these.

THREE NUMBERS PER CAPTURE:
    found    real blinks that were counted
    missed   real blinks that were not
    false    blinks counted where there was none (or a second count of the same blink)
A "partial" blink (lids half-way down) is neither required nor held against the detector.
"""

import argparse
import csv
from dataclasses import dataclass, replace

import numpy as np
import torch
from PIL import Image

from annotate import KINDS
from captures import Capture, all_captures
from data import EyeData, load
from detector import Settings, count_blinks
from learning import device, predict, train
from paths import RAW

# A blink is counted at the frame where the eyes reopen, just after its candidate; and a
# candidate's first frame can be a frame late. A count this close to a candidate is that
# candidate's.
FRAMES_BEFORE, FRAMES_AFTER = 2, 5

# The first version's rule: two closed frames, always (see BlinkDetector.swift).
FIRST_RULES = replace(Settings(), single_frame_sure=2.0)


@dataclass(frozen=True)
class Truth:
    """One candidate of a capture, as a person marked it."""

    first: int  # positions in capture.frames
    last: int
    kind: str  # blink, partial or none


@dataclass(frozen=True)
class Rule:
    """A way of counting: how the two eyes are combined, and the detector's settings."""

    name: str
    fusion: str = "average"
    settings: Settings = Settings()

    def count(self, capture: Capture, left: list[float], right: list[float]) -> list[int]:
        combine = max if self.fusion == "maximum" else (lambda a, b: (a + b) / 2)
        return count_blinks(
            capture.times,
            [combine(a, b) for a, b in zip(left, right, strict=True)],
            self.settings,
            capture.levels,
        )


@dataclass
class Score:
    blinks: int = 0
    found: int = 0
    false: int = 0
    seconds: float = 0.0

    @property
    def missed(self) -> int:
        return self.blinks - self.found

    def __add__(self, other: "Score") -> "Score":
        return Score(
            self.blinks + other.blinks,
            self.found + other.found,
            self.false + other.false,
            self.seconds + other.seconds,
        )

    def __str__(self) -> str:
        per_minute = self.false / self.seconds * 60 if self.seconds else 0.0
        return (
            f"{self.found:3d} of {self.blinks:3d} found ({100 * self.found / max(self.blinks, 1):5.1f}%)"
            f"   {self.missed:2d} missed   {self.false:2d} false ({per_minute:.1f} a minute)"
        )


def read_truth(capture: Capture) -> list[Truth]:
    answers = capture.folder / "blinks.csv"
    if not answers.is_file():
        raise SystemExit(f"{capture.name} has no ground truth yet: run annotate.py and fill {answers}")
    truth = []
    with answers.open(newline="", encoding="utf-8") as handle:
        for line in csv.DictReader(handle):
            if line["kind"] not in KINDS:
                raise SystemExit(f"{answers}: candidate {line['id']} has no kind ({' / '.join(KINDS)})")
            first = capture.index_of_frame(int(line["first_frame"]))
            last = capture.index_of_frame(int(line["last_frame"]))
            truth.append(Truth(first, last, line["kind"]))
    return truth


def score(capture: Capture, truth: list[Truth], counted: list[int]) -> Score:
    """Compares the frames at which blinks were counted with the ground truth."""
    result = Score(blinks=sum(1 for t in truth if t.kind == "blink"), seconds=capture.seconds)
    used: set[int] = set()
    for frame in counted:
        match = next(
            (n for n, t in enumerate(truth) if t.first - FRAMES_BEFORE <= frame <= t.last + FRAMES_AFTER),
            None,
        )
        if match is None or truth[match].kind == "none" or match in used:
            result.false += 1
        elif truth[match].kind == "blink":
            used.add(match)
            result.found += 1
    return result


def eye_pictures(capture: Capture, side: str) -> torch.Tensor:
    """One eye's pictures, frame by frame, as (frames, 3, 64, 64)."""
    files = [capture.picture(frame, side) for frame in capture.frames]
    stack = np.stack([np.asarray(Image.open(f).convert("RGB")) for f in files])
    return torch.from_numpy(stack).permute(0, 3, 1, 2).contiguous()


def answers_without(
    capture: Capture, data: EyeData, on: torch.device, seed: int
) -> tuple[list[float], list[float]]:
    """Each eye's answers on a capture, from a model trained without that capture."""
    rest = data.indices(set(data.sessions) - {capture.name}).to(on)
    model = train(data.images.to(on)[rest], data.labels.to(on)[rest], epochs=30, seed=seed)
    return tuple(predict(model, eye_pictures(capture, side).to(on)).tolist() for side in ("L", "R"))


def as_counted_live(captures: list[Capture], truths: dict[str, list[Truth]]) -> None:
    """Prints how the app itself counted each capture, on the day it was recorded."""
    print("\nAs the app counted them when they were recorded (the model of that day):")
    total = Score()
    for capture in captures:
        live = [i for i, frame in enumerate(capture.frames) if frame.counted]
        # The rules written in Python must be the app's rules: replaying the answers the
        # app recorded has to count the very blinks the app counted. A capture made
        # before 2026-11-20 was counted with the first rules, a later one with today's.
        recorded = [frame.mean for frame in capture.frames]
        replays = (
            count_blinks(capture.times, recorded, levels=capture.levels),
            count_blinks(capture.times, recorded, FIRST_RULES),
        )
        if live not in replays:
            raise SystemExit(f"{capture.name}: the Python rules do not reproduce the app's count")
        result = score(capture, truths[capture.name], live)
        total += result
        print(f"  {capture.name:26s} {result}")
    print(f"  {'all':26s} {total}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Blink-level accuracy on the annotated captures.")
    parser.add_argument("--seeds", type=int, default=1, help="trainings per capture (results are added up)")
    parser.add_argument("--experiments", action="store_true", help="compare training and counting variants")
    arguments = parser.parse_args()

    on = device()
    captures = all_captures()
    truths = {capture.name: read_truth(capture) for capture in captures}
    seconds = sum(c.seconds for c in captures)
    real = sum(1 for truth in truths.values() for t in truth if t.kind == "blink")
    print(f"\n{len(captures)} captures, {seconds:.0f} s of video, {real} real blinks marked by eye.")
    as_counted_live(captures, truths)

    rules = [Rule("current rules")]
    trainings = {"current training": load()}
    if arguments.experiments:
        rules += [
            Rule("two frames always", settings=FIRST_RULES),
            Rule("either eye (maximum)", fusion="maximum"),
            Rule("any single frame", settings=replace(Settings(), minimum_closed_frames=1)),
            Rule("one frame if >= 90%", settings=replace(Settings(), single_frame_sure=0.9)),
        ]
        trainings["recorder sessions only (no real blink frames)"] = load((RAW,))

    several = f", {arguments.seeds} trainings added up" if arguments.seeds > 1 else ""
    for name, data in trainings.items():
        by_rule = {rule.name: Score() for rule in rules}
        by_capture = {capture.name: Score() for capture in captures}
        for seed in range(arguments.seeds):
            for capture in captures:
                left, right = answers_without(capture, data, on, seed=7 + seed)
                for rule in rules:
                    result = score(capture, truths[capture.name], rule.count(capture, left, right))
                    by_rule[rule.name] += result
                    if rule is rules[0]:
                        by_capture[capture.name] += result

        print(f"\nModel: {name}  (each capture judged by a model that never saw it{several})")
        if not arguments.experiments:
            for capture_name, result in by_capture.items():
                print(f"  {capture_name:26s} {result}")
        for rule_name, result in by_rule.items():
            print(f"  {rule_name:26s} {result}")


if __name__ == "__main__":
    main()
