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

import os

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import argparse
import csv
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np
import torch
from PIL import Image

from data import DATA_ROOT, load
from detector import Settings, count_blinks
from train import predict, train

HERE = Path(__file__).resolve().parent
LIVE = HERE.parent / "data" / "live"


@dataclass
class Capture:
    name: str
    rows: list[dict]  # the trace lines where both eyes were read
    times: list[float]
    left: torch.Tensor  # the eye pictures, (frames, 3, 64, 64)
    right: torch.Tensor
    truth: list[tuple[int, int, str]]  # (first row, last row, kind) per candidate

    @property
    def seconds(self) -> float:
        return self.times[-1] - self.times[0]

    @property
    def real_blinks(self) -> int:
        return sum(1 for _, _, kind in self.truth if kind == "blink")


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


def read_capture(folder: Path) -> Capture:
    with (folder / "trace.csv").open(newline="", encoding="utf-8") as handle:
        rows = [r for r in csv.DictReader(handle) if r["p_left"] and r["p_right"]]
    row_of_frame = {r["frame"]: i for i, r in enumerate(rows)}

    def pictures(side: str) -> torch.Tensor:
        files = [folder / "frames" / f"f{int(r['frame']):06d}_{side}.png" for r in rows]
        stack = np.stack([np.asarray(Image.open(f).convert("RGB")) for f in files])
        return torch.from_numpy(stack).permute(0, 3, 1, 2).contiguous()

    answers = folder / "blinks.csv"
    if not answers.is_file():
        raise SystemExit(f"{folder.name} has no ground truth yet: run annotate.py and fill {answers}")
    truth = []
    with answers.open(newline="", encoding="utf-8") as handle:
        for line in csv.DictReader(handle):
            if line["kind"] not in ("blink", "partial", "none"):
                raise SystemExit(f"{answers}: candidate {line['id']} has no kind (blink / partial / none)")
            truth.append((row_of_frame[line["first_frame"]], row_of_frame[line["last_frame"]], line["kind"]))

    return Capture(folder.name, rows, [float(r["time"]) for r in rows], pictures("L"), pictures("R"), truth)


def score(capture: Capture, counted: list[int]) -> Score:
    """Compares the frames at which blinks were counted with the ground truth."""
    result = Score(blinks=capture.real_blinks, seconds=capture.seconds)
    used: set[int] = set()
    for frame in counted:
        # A blink is counted at the frame where the eyes reopen: just after its candidate.
        match = next(
            (n for n, (first, last, _) in enumerate(capture.truth) if first - 2 <= frame <= last + 5),
            None,
        )
        if match is None:
            result.false += 1
            continue
        kind = capture.truth[match][2]
        if kind == "partial":
            continue
        if kind == "none" or match in used:
            result.false += 1
        else:
            used.add(match)
            result.found += 1
    return result


def fuse(left: list[float], right: list[float], how: str) -> list[float]:
    if how == "average":
        return [(a + b) / 2 for a, b in zip(left, right, strict=True)]
    if how == "maximum":
        return [max(a, b) for a, b in zip(left, right, strict=True)]
    raise ValueError(how)


def answers_without(capture: Capture, data, device, seed: int, **options) -> tuple[list[float], list[float]]:
    """Each eye's answers on a capture, from a model trained without that capture."""
    rest = data.indices(set(data.sessions) - {capture.name}).to(device)
    model = train(data.images.to(device)[rest], data.labels.to(device)[rest], epochs=30, seed=seed, **options)
    return predict(model, capture.left.to(device)).tolist(), predict(model, capture.right.to(device)).tolist()


def main() -> None:
    parser = argparse.ArgumentParser(description="Blink-level accuracy on the annotated captures.")
    parser.add_argument("--seeds", type=int, default=1, help="trainings per capture (results are added up)")
    parser.add_argument("--experiments", action="store_true", help="compare training and counting variants")
    arguments = parser.parse_args()

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    captures = [read_capture(p) for p in sorted(LIVE.iterdir()) if (p / "trace.csv").is_file()]
    data = load()
    total_seconds = sum(c.seconds for c in captures)
    total_blinks = sum(c.real_blinks for c in captures)
    print(f"\n{len(captures)} captures, {total_seconds:.0f} s of video,", end=" ")
    print(f"{total_blinks} real blinks marked by eye.")

    # The rules written in Python must be the app's rules: replaying the answers the app
    # recorded has to count the very blinks the app counted. A capture made before
    # 2026-11-20 was counted with the first rules (two frames always), a later one with
    # today's: the replay must reproduce the count with one of the two.
    first_rules = replace(Settings(), single_frame_sure=2.0)
    print("\nAs the app counted them when they were recorded (the model of that day):")
    live_total = Score()
    for capture in captures:
        answers = [float(r["p_mean"]) for r in capture.rows]
        live = [i for i, r in enumerate(capture.rows) if r["event"] == "blink"]
        if live not in (
            count_blinks(capture.times, answers),
            count_blinks(capture.times, answers, first_rules),
        ):
            raise SystemExit(f"{capture.name}: the Python rules do not reproduce the app's count")
        result = score(capture, live)
        live_total += result
        print(f"  {capture.name:26s} {result}")
    print(f"  {'all':26s} {live_total}")

    variants: dict[str, dict] = {"current training": {}}
    if arguments.experiments:
        variants["recorder sessions only (no real blink frames)"] = {"sessions_only": True}

    rules = {"current rules": ("average", Settings())}
    if arguments.experiments:
        rules |= {
            "two frames always": ("average", first_rules),
            "either eye (maximum)": ("maximum", Settings()),
            "any single frame": ("average", replace(Settings(), minimum_closed_frames=1)),
            "one frame if >= 90%": ("average", replace(Settings(), single_frame_sure=0.9)),
        }

    for variant, options in variants.items():
        sessions_only = options.pop("sessions_only", False)
        training_data = load((DATA_ROOT,)) if sessions_only else data
        totals = {name: Score() for name in rules}
        per_capture = {c.name: Score() for c in captures}
        for seed in range(arguments.seeds):
            for capture in captures:
                left, right = answers_without(capture, training_data, device, seed=7 + seed, **options)
                for name, (how, settings) in rules.items():
                    result = score(capture, count_blinks(capture.times, fuse(left, right, how), settings))
                    totals[name] += result
                    if name == "current rules":
                        per_capture[capture.name] += result

        print(
            f"\nModel: {variant}  (each capture judged by a model that never saw it"
            + (f", {arguments.seeds} trainings added up)" if arguments.seeds > 1 else ")")
        )
        if not arguments.experiments:
            for name, result in per_capture.items():
                print(f"  {name:26s} {result}")
        for name, result in totals.items():
            print(f"  {name:26s} {result}")


if __name__ == "__main__":
    main()
