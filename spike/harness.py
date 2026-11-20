"""SPIKE (step 1 of the in-app onboarding work): one harness, several training engines.

The question: can training live inside the app, and is it as good as the Python route?
To compare engines on THE SAME data and THE SAME splits, the splits are made here, once,
as a list of "jobs" (train on these pictures, answer on those). Each engine runs the jobs
and returns its answers; the scoring below is the project's own (training/evaluate.py).

    uv run python ../spike/harness.py export  jobs.json           write the jobs for another engine
    uv run python ../spike/harness.py python  results-python.json run them with the Python route
    uv run python ../spike/harness.py score   results-x.json      the tables

The recordings are only read (from BLINK_HOME/data when the variable is set). Nothing is copied.
"""

# ruff: noqa: E402  (settings come before some imports, on purpose)

import itertools
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def home() -> Path:
    """The checkout that holds data/ and models/: the one named by BLINK_HOME, else this
    one, else (in a git worktree, which has no recordings of its own) the main checkout.
    The recordings are read where they are, never copied."""
    if "BLINK_HOME" in os.environ:
        return Path(os.environ["BLINK_HOME"]).resolve()
    if (HERE.parent / "data").is_dir():
        return HERE.parent
    asked = ["git", "-C", str(HERE), "rev-parse", "--path-format=absolute", "--git-common-dir"]
    shared = subprocess.run(asked, capture_output=True, text=True, check=False).stdout.strip()
    return Path(shared).parent if shared else HERE.parent


MAIN = home()
sys.path.insert(0, str(HERE.parent / "training"))

import paths  # noqa: E402

# Point the training code at the main checkout's data before anything else imports it.
paths.DATA = MAIN / "data"
paths.RAW, paths.LIVE, paths.BLINKS = paths.DATA / "raw", paths.DATA / "live", paths.DATA / "blinks"
paths.MODELS = MAIN / "models"
paths.MODEL_FILE = paths.MODELS / "eyenet.pt"

from captures import all_captures  # noqa: E402
from data import load  # noqa: E402
from evaluate import Rule, Score, read_truth, score  # noqa: E402

EPOCHS = 30
# evaluate.py uses seed 7; more seeds show how much a seed moves the count.
# SPIKE_SEEDS=7,8,...  and  SPIKE_ONLY=eval/  narrow a run to the blink-counting question.
EVAL_SEEDS = tuple(int(s) for s in os.environ.get("SPIKE_SEEDS", "7,8,9").split(","))
ONLY = os.environ.get("SPIKE_ONLY", "")


def build():
    """The picture table (every training picture, then every capture frame) and the jobs."""
    data = load((paths.RAW, paths.BLINKS))
    captures = all_captures(paths.LIVE)

    pictures = [row["path"] for row in data.rows]
    labels = [int(label) for label in data.labels.tolist()]
    frames_of: dict[str, dict[str, list[int]]] = {}
    for capture in captures:
        frames_of[capture.name] = {}
        for side in ("L", "R"):
            start = len(pictures)
            pictures += [str(capture.picture(frame, side)) for frame in capture.frames]
            labels += [-1] * len(capture.frames)
            frames_of[capture.name][side] = list(range(start, len(pictures)))
    all_frames = [i for sides in frames_of.values() for index in sides.values() for i in index]

    def rows_in(sessions: set[str]) -> list[int]:
        return data.indices(sessions).tolist()

    raw = sorted(p.name for p in paths.RAW.iterdir() if (p / "manifest.csv").is_file())
    jobs = []
    # A. Cross-validation by session, as `make train` does it (seed 0 + fold).
    for fold, held_out in enumerate(data.sessions):
        jobs.append(
            {
                "name": f"cv/{held_out}",
                "train": rows_in(set(data.sessions) - {held_out}),
                "predict": rows_in({held_out}),
                "seed": fold,
            }
        )
    # B. Blink counting, as `make evaluate` does it: each capture judged by a model
    #    trained without that capture's pictures.
    for seed in EVAL_SEEDS:
        for capture in captures:
            jobs.append(
                {
                    "name": f"eval/{seed}/{capture.name}",
                    "train": rows_in(set(data.sessions) - {capture.name}),
                    "predict": frames_of[capture.name]["L"] + frames_of[capture.name]["R"],
                    "seed": seed,
                }
            )
    # C. What a NEW user has: recorder sessions only, 1 to 4 of them, no real blink frame.
    #    Tested on the recorder sessions left out, and on the three captures.
    number = 0
    for k in range(1, len(raw) + 1):
        for subset in itertools.combinations(raw, k):
            jobs.append(
                {
                    "name": f"curve/{k}/{'+'.join(s[-6:] for s in subset)}",
                    "train": rows_in(set(subset)),
                    "predict": rows_in(set(raw) - set(subset)) + all_frames,
                    "seed": 100 + number,
                }
            )
            number += 1
    jobs = [job for job in jobs if job["name"].startswith(ONLY)]
    for job in jobs:
        job["epochs"] = EPOCHS
    return data, captures, pictures, labels, frames_of, jobs


def export(target: Path) -> None:
    _, _, pictures, labels, _, jobs = build()
    target.write_text(json.dumps({"pictures": pictures, "labels": labels, "jobs": jobs}))
    print(f"{len(pictures)} pictures, {len(jobs)} jobs -> {target}")


def run_python(target: Path) -> None:
    import numpy as np
    import torch
    from PIL import Image

    from learning import device, predict, train

    _, _, pictures, labels, _, jobs = build()
    on = device()
    stack = np.stack([np.asarray(Image.open(p).convert("RGB")) for p in pictures])
    images = torch.from_numpy(stack).permute(0, 3, 1, 2).contiguous().to(on)
    truth = torch.tensor(labels, dtype=torch.float32).to(on)

    results = {}
    for job in jobs:
        started = time.time()
        index = torch.tensor(job["train"]).to(on)
        model = train(images[index], truth[index], epochs=job["epochs"], seed=job["seed"])
        seconds = time.time() - started
        answers = predict(model, images[torch.tensor(job["predict"]).to(on)]).tolist()
        results[job["name"]] = {"closed": answers, "seconds": seconds}
        print(f"  {job['name']:44s} {len(job['train']):5d} pictures  {seconds:5.1f} s", flush=True)
    target.write_text(json.dumps(results))


def tables(source: Path) -> None:
    data, captures, _, labels, frames_of, jobs = build()
    results = json.loads(source.read_text())
    by_name = {job["name"]: job for job in jobs}
    truths = {capture.name: read_truth(capture) for capture in captures}
    rule = Rule("current rules")

    def answers(name: str) -> dict[int, float]:
        return dict(zip(by_name[name]["predict"], results[name]["closed"], strict=True))

    def count(found: dict[int, float], capture) -> Score:
        left = [found[i] for i in frames_of[capture.name]["L"]]
        right = [found[i] for i in frames_of[capture.name]["R"]]
        return score(capture, truths[capture.name], rule.count(capture, left, right))

    def wrong(found: dict[int, float], rows: list[int]) -> tuple[int, int, int]:
        phantom = sum(1 for i in rows if found[i] > 0.5 and labels[i] == 0)
        missed = sum(1 for i in rows if found[i] <= 0.5 and labels[i] == 1)
        return phantom, missed, len(rows)

    seconds = [results[name]["seconds"] for name in results]
    print(f"\n{source.name}: {len(results)} trainings, {min(seconds):.1f} to {max(seconds):.1f} s each")

    print("\nA. Pictures of a session never seen (cross-validation by session)")
    phantom = missed = total = 0
    for job in jobs:
        if job["name"].startswith("cv/") and job["name"] in results:
            p, m, n = wrong(answers(job["name"]), job["predict"])
            phantom, missed, total = phantom + p, missed + m, total + n
            took = results[job["name"]]["seconds"]
            print(f"  {job['name'][3:]:28s} {p + m:3d} wrong of {n:4d}   ({took:.1f} s)")
    if total:
        print(
            f"  all: {100 * (1 - (phantom + missed) / total):.2f}% right; "
            f"open called closed {phantom}, closed called open {missed}, of {total}"
        )

    print("\nB. Blinks counted, each capture judged by a model trained without it")
    seeds = sorted({name.split("/")[1] for name in results if name.startswith("eval/")})
    for seed in seeds:
        total_score = Score()
        parts = []
        for capture in captures:
            result = count(answers(f"eval/{seed}/{capture.name}"), capture)
            total_score += result
            parts.append(f"{result.found}/{result.blinks}+{result.false}f")
        print(f"  seed {seed}: {total_score}    [{'  '.join(parts)}]")

    print("\nC. Recorder sessions only (what a new user has), by number of sessions")
    raw = sorted({row["session"] for row in data.rows if "/raw/" in row["path"]})
    for k in range(1, len(raw) + 1):
        lines = []
        for name in sorted(n for n in results if n.startswith(f"curve/{k}/")):
            found = answers(name)
            held = [i for i in by_name[name]["predict"] if labels[i] >= 0]
            total_score = Score()
            for capture in captures:
                total_score += count(found, capture)
            p, m, n = wrong(found, held) if held else (0, 0, 0)
            accuracy = f"{100 * (1 - (p + m) / n):6.2f}% of {n}" if n else "      -        "
            lines.append((name.split("/")[2], accuracy, total_score, results[name]["seconds"]))
        for subset, accuracy, total_score, took in lines:
            print(
                f"  {k} session(s) {subset:28s} pictures {accuracy}   blinks {total_score.found:2d} of "
                f"{total_score.blinks}, {total_score.false} false   ({took:.1f} s)"
            )
        if lines:
            found = [line[2].found for line in lines]
            false = [line[2].false for line in lines]
            print(
                f"    -> {k}: found {min(found)} to {max(found)} (mean {sum(found) / len(found):.1f}) of 72; "
                f"false {min(false)} to {max(false)} (mean {sum(false) / len(false):.1f})"
            )


if __name__ == "__main__":
    command, target = sys.argv[1], Path(sys.argv[2]).resolve()
    {"export": export, "python": run_python, "score": tables}[command](target)
